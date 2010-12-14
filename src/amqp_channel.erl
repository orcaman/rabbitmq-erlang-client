%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
%%

%% @doc This module encapsulates the client's view of an AMQP
%% channel. Each server side channel is represented by an amqp_channel
%% process on the client side. Channel processes are created using the
%% {@link amqp_connection} module. Channel processes are supervised
%% under amqp_client's supervision tree.
-module(amqp_channel).

-include("amqp_client.hrl").

-behaviour(gen_server).

-export([start_link/3, connection_closing/2]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([call/2, call/3, cast/2, cast/3]).
-export([subscribe/3]).
-export([close/1, close/3]).
-export([register_return_handler/2]).
-export([register_flow_handler/2]).
-export([register_ack_handler/2]).
-export([get_published_message_count/1]).
-export([register_default_consumer/2]).

-define(TIMEOUT_FLUSH, 60000).
-define(TIMEOUT_CLOSE_OK, 3000).

-record(state, {number,
                sup,
                driver,
                rpc_requests        = queue:new(),
                anon_sub_requests   = queue:new(),
                tagged_sub_requests = dict:new(),
                closing             = false,
                writer,
                return_handler_pid  = none,
                ack_handler_pid     = none,
                pub_msg_count       = undefined,
                flow_active         = true,
                flow_handler_pid    = none,
                consumers           = dict:new(),
                default_consumer    = none,
                start_writer_fun
               }).

%%---------------------------------------------------------------------------
%% Type Definitions
%%---------------------------------------------------------------------------

%% @type amqp_method().
%% This abstract datatype represents the set of methods that comprise
%% the AMQP execution model. As indicated in the overview, the
%% attributes of each method in the execution model are described in
%% the protocol documentation. The Erlang record definitions are
%% autogenerated from a parseable version of the specification. Most
%% fields in the generated records have sensible default values that
%% you need not worry in the case of a simple usage of the client
%% library.

%% @type amqp_msg() = #amqp_msg{}.
%% This is the content encapsulated in content-bearing AMQP methods. It
%% contains the following fields:
%% <ul>
%% <li>props :: class_property() - A class property record, defaults to
%%     #'P_basic'{}</li>
%% <li>payload :: binary() - The arbitrary data payload</li>
%% </ul>

%%---------------------------------------------------------------------------
%% AMQP Channel API methods
%%---------------------------------------------------------------------------

%% @spec (Channel, Method) -> Result
%% @doc This is equivalent to amqp_channel:call(Channel, Method, none).
call(Channel, Method) ->
    gen_server:call(Channel, {call, Method, none}, infinity).

%% @spec (Channel, Method, Content) -> Result
%% where
%%      Channel = pid()
%%      Method = amqp_method()
%%      Content = amqp_msg() | none
%%      Result = amqp_method() | ok | blocked | closing
%% @doc This sends an AMQP method on the channel.
%% For content bearing methods, Content has to be an amqp_msg(), whereas
%% for non-content bearing methods, it needs to be the atom 'none'.<br/>
%% In the case of synchronous methods, this function blocks until the
%% corresponding reply comes back from the server and returns it.
%% In the case of asynchronous methods, the function blocks until the method
%% gets sent on the wire and returns the atom 'ok' on success.<br/>
%% This will return the atom 'blocked' if the server has
%% throttled the  client for flow control reasons. This will return the
%% atom 'closing' if the channel is in the process of shutting down.<br/>
%% Note that for asynchronous methods, the synchronicity implied by
%% 'call' only means that the client has transmitted the method to
%% the broker. It does not necessarily imply that the broker has
%% accepted responsibility for the message.
call(Channel, Method, Content) ->
    gen_server:call(Channel, {call, Method, Content}, infinity).

%% @spec (Channel, Method) -> ok
%% @doc This is equivalent to amqp_channel:cast(Channel, Method, none).
cast(Channel, Method) ->
    gen_server:cast(Channel, {cast, Method, none}).

%% @spec (Channel, Method, Content) -> ok
%% where
%%      Channel = pid()
%%      Method = amqp_method()
%%      Content = amqp_msg() | none
%% @doc This function is the same as {@link call/3}, except that it returns
%% immediately with the atom 'ok', without blocking the caller process.
%% This function is not recommended with synchronous methods, since there is no
%% way to verify that the server has received the method.
cast(Channel, Method, Content) ->
    gen_server:cast(Channel, {cast, Method, Content}).

%% @spec (Channel) -> ok
%% where
%%      Channel = pid()
%% @doc Closes the channel, invokes
%% close(Channel, 200, &lt;&lt;"Goodbye"&gt;&gt;).
close(Channel) ->
    close(Channel, 200, <<"Goodbye">>).

%% @spec (Channel, Code, Text) -> ok
%% where
%%      Channel = pid()
%%      Code = integer()
%%      Text = binary()
%% @doc Closes the channel, allowing the caller to supply a reply code and
%% text.
close(Channel, Code, Text) ->
    Close = #'channel.close'{reply_text = Text,
                             reply_code = Code,
                             class_id   = 0,
                             method_id  = 0},
    case call(Channel, Close) of
        #'channel.close_ok'{} -> ok;
        Error                 -> Error
    end.

%% @spec (Channel) -> integer()
%% where
%%      Channel = pid()
%% @doc Returns the number of published messages since the channel was put
%% in confirm mode
get_published_message_count(Channel) ->
    gen_server:call(Channel, get_published_message_count).

%%---------------------------------------------------------------------------
%% Consumer registration (API)
%%---------------------------------------------------------------------------

%% @type consume() = #'basic.consume'{}.
%% The AMQP method that is used to  subscribe a consumer to a queue.
%% @spec (Channel, consume(), Consumer) -> amqp_method()
%% where
%%      Channel = pid()
%%      Consumer = pid()
%% @doc Creates a subscription to a queue. This subscribes a consumer pid to
%% the queue defined in the #'basic.consume'{} method record. Note that
%% both the process invoking this method and the supplied consumer process
%% receive an acknowledgement of the subscription. The calling process will
%% receive the acknowledgement as the return value of this function, whereas
%% the consumer process will receive the notification asynchronously.
subscribe(Channel, BasicConsume = #'basic.consume'{}, Consumer) ->
    gen_server:call(Channel, {subscribe, BasicConsume, Consumer}, infinity).

%% @spec (Channel, ReturnHandler) -> ok
%% where
%%      Channel = pid()
%%      ReturnHandler = pid()
%% @doc This registers a handler to deal with returned messages. The
%% registered process will receive #basic.return{} records.
register_return_handler(Channel, ReturnHandler) ->
    gen_server:cast(Channel, {register_return_handler, ReturnHandler} ).

%% @spec (Channel, AckHandler) -> ok
%% where
%%      Channel = pid()
%%      AckHandler = pid()
%% @doc This registers a handler to deal with ack'd messages. The
%% registered process will receive #basic.ack{} commands.
register_ack_handler(Channel, AckHandler) ->
    gen_server:cast(Channel, {register_ack_handler, AckHandler} ).

%% @spec (Channel, FlowHandler) -> ok
%% where
%%      Channel = pid()
%%      FlowHandler = pid()
%% @doc This registers a handler to deal with channel flow notifications.
%% The registered process will receive #channel.flow{} records.
register_flow_handler(Channel, FlowHandler) ->
    gen_server:cast(Channel, {register_flow_handler, FlowHandler} ).

%% @spec (Channel, Consumer) -> ok
%% where
%%      Channel = pid()
%%      Consumer = pid()
%% @doc Set the current default consumer.
%% Under certain circumstances it is possible for a channel to receive a
%% message delivery which does not match any consumer which is currently
%% set up via basic.consume. This will occur after the following sequence
%% of events:<br/>
%% <br/>
%% basic.consume with explicit acks<br/>
%% %% some deliveries take place but are not acked<br/>
%% basic.cancel<br/>
%% basic.recover{requeue = false}<br/>
%% <br/>
%% Since requeue is specified to be false in the basic.recover, the spec
%% states that the message must be redelivered to "the original recipient"
%% - i.e. the same channel / consumer-tag. But the consumer is no longer
%% active.<br/>
%% In these circumstances, you can register a default consumer to handle
%% such deliveries. If no default consumer is registered then the channel
%% will exit on receiving such a delivery.<br/>
%% Most people will not need to use this.
register_default_consumer(Channel, Consumer) ->
    gen_server:cast(Channel, {register_default_consumer, Consumer}).

%%---------------------------------------------------------------------------
%% RPC mechanism
%%---------------------------------------------------------------------------

handle_method_call(Method, AmqpMsg, From, State) ->
    case {Method, From, check_block(Method, AmqpMsg, State)} of
        {#'basic.consume'{}, none, _} ->
            ?LOG_WARN("Channel (~p): ignoring cast of ~p method. "
                      "Use subscribe/3 instead!~n", [self(), Method]),
            {noreply, State};
        {#'basic.consume'{}, _, _} ->
            {reply, {error, use_subscribe}, State};
        {_, _, ok} ->
            State1 = case {Method, State} of
                         {#'confirm.select'{}, _} ->
                             State #state { pub_msg_count = 0 };
                         {#'basic.publish'{},
                          #state { pub_msg_count = undefined }} ->
                             State;
                         {#'basic.publish'{},
                          #state { pub_msg_count = PMC }} ->
                             State #state { pub_msg_count = PMC + 1 };
                         _ -> State
                     end,
            {noreply,
             rpc_top_half(Method, build_content(AmqpMsg), From, State1)};
        {_, none, BlockReply} ->
            ?LOG_WARN("Channel (~p): discarding method ~p in cast.~n"
                      "Reason: ~p~n", [self(), Method, BlockReply]),
            {noreply, State};
        {_, _, BlockReply} ->
            {reply, BlockReply, State}
    end.

rpc_top_half(Method, Content, From,
             State0 = #state{rpc_requests = RequestQueue}) ->
    State1 = State0#state{
        rpc_requests = queue:in({From, Method, Content}, RequestQueue)},
    IsFirstElement = queue:is_empty(RequestQueue),
    if IsFirstElement -> do_rpc(State1);
       true           -> State1
    end.

rpc_bottom_half(Reply, State = #state{rpc_requests = RequestQueue}) ->
    {{value, {From, _Method, _Content}}, RequestQueue1} =
        queue:out(RequestQueue),
    case From of none -> ok;
                 _    -> gen_server:reply(From, Reply)
    end,
    do_rpc(State#state{rpc_requests = RequestQueue1}).

do_rpc(State = #state{rpc_requests = Q,
                      closing      = Closing}) ->
    case queue:out(Q) of
        {{value, {From, Method, Content}}, NewQ} ->
            State1 = pre_do(Method, Content, State),
            DoRet = do(Method, Content, State1),
            case ?PROTOCOL:is_method_synchronous(Method) of
                true  -> State1;
                false -> case {From, DoRet} of
                             {none, _} -> ok;
                             {_, ok}   -> gen_server:reply(From, ok)
                             %% Do not reply if error in do. Expecting
                             %% {channel_exit, ...}
                         end,
                         do_rpc(State1#state{rpc_requests = NewQ})
            end;
        {empty, NewQ} ->
            case Closing of
                connection -> self() ! {shutdown, connection_closing};
                _          -> ok
            end,
            State#state{rpc_requests = NewQ}
    end.

pre_do(#'channel.open'{}, _Content, State) ->
    start_writer(State);
pre_do(#'channel.close'{}, _Content, State) ->
    State#state{closing = just_channel};
pre_do(_, _, State) ->
    State.

%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

do(Method, Content, #state{driver = Driver, writer = W}) ->
    %% Catching because it expects the {channel_exit, _, _} message on error
    catch case {Driver, Content} of
              {network, none} -> rabbit_writer:send_command_sync(W, Method);
              {network, _}    -> rabbit_writer:send_command_sync(W, Method,
                                                                 Content);
              {direct, none}  -> rabbit_channel:do(W, Method);
              {direct, _}     -> rabbit_channel:do(W, Method, Content)
          end.

start_writer(State = #state{start_writer_fun = SWF}) ->
    {ok, Writer} = SWF(),
    State#state{writer = Writer}.

resolve_consumer(_ConsumerTag, #state{consumers = []}) ->
    exit(no_consumers_registered);
resolve_consumer(ConsumerTag, #state{consumers = Consumers,
                                     default_consumer = DefaultConsumer}) ->
    case dict:find(ConsumerTag, Consumers) of
        {ok, Value} ->
            Value;
        error ->
            case is_pid(DefaultConsumer) of
                true  -> DefaultConsumer;
                false -> exit(unexpected_delivery_and_no_default_consumer)
            end
    end.

register_consumer(ConsumerTag, Consumer,
                  State = #state{consumers = Consumers0}) ->
    Consumers1 = dict:store(ConsumerTag, Consumer, Consumers0),
    State#state{consumers = Consumers1}.

unregister_consumer(ConsumerTag,
                    State = #state{consumers = Consumers0}) ->
    Consumers1 = dict:erase(ConsumerTag, Consumers0),
    State#state{consumers = Consumers1}.

amqp_msg(none) ->
    none;
amqp_msg(Content) ->
    {Props, Payload} = rabbit_basic:from_content(Content),
    #amqp_msg{props = Props, payload = Payload}.

build_content(none) ->
    none;
build_content(#amqp_msg{props = Props, payload = Payload}) ->
    rabbit_basic:build_content(Props, Payload).

check_block(_Method, _AmqpMsg, #state{closing = just_channel}) ->
    closing;
check_block(_Method, _AmqpMsg, #state{closing = connection}) ->
    closing;
check_block(_Method, none, #state{}) ->
    ok;
check_block(_Method, #amqp_msg{}, #state{flow_active = false}) ->
    blocked;
check_block(_Method, _AmqpMsg, #state{}) ->
    ok.

is_connection_method(Method) ->
    {ClassId, _} = ?PROTOCOL:method_id(element(1, Method)),
    ?PROTOCOL:lookup_class_name(ClassId) == connection.

server_misbehaved(#amqp_error{} = AmqpError, State = #state{number = Number}) ->
    case rabbit_binary_generator:map_exception(Number, AmqpError, ?PROTOCOL) of
        {true, _, _} ->
            {stop, {server_misbehaved, AmqpError}, State};
        {false, _, Close} ->
            ?LOG_WARN("Channel (~p) flushing and closing due to soft "
                      "error caused by the server ~p~n", [self(), AmqpError]),
            Self = self(),
            spawn(fun() -> call(Self, Close) end),
            {noreply, State}
    end.

%%---------------------------------------------------------------------------
%% Handling of methods from the server
%%---------------------------------------------------------------------------

handle_method(Method, Content, State = #state{closing = Closing}) ->
    case is_connection_method(Method) of
        true -> server_misbehaved(
                    #amqp_error{name        = command_invalid,
                                explanation = "connection method on "
                                              "non-zero channel",
                                method      = element(1, Method)},
                    State);
        false -> Drop = case {Closing, Method} of
                            {just_channel, #'channel.close'{}}    -> false;
                            {just_channel, #'channel.close_ok'{}} -> false;
                            {just_channel, _}                     -> true;
                            _                                     -> false
                        end,
                 if Drop -> ?LOG_INFO("Channel (~p): dropping method ~p from "
                                      "server because channel is closing~n",
                                      [self(), {Method, Content}]),
                                      {noreply, State};
                    true -> handle_method1(Method, amqp_msg(Content), State)
                 end
    end.

handle_method1(#'channel.close'{reply_code = Code, reply_text = Text}, none,
               State) ->
    do(#'channel.close_ok'{}, none, State),
    {stop, {server_initiated_close, Code, Text}, State};
handle_method1(#'channel.close_ok'{} = CloseOk, none, State) ->
    {stop, normal, rpc_bottom_half(CloseOk, State)};
handle_method1(#'basic.consume_ok'{consumer_tag = ConsumerTag} = ConsumeOk,
               none, State = #state{tagged_sub_requests = Tagged,
                                    anon_sub_requests = Anon}) ->
    {Consumer, State0} =
        case dict:find(ConsumerTag, Tagged) of
            {ok, C} ->
                NewTagged = dict:erase(ConsumerTag, Tagged),
                {C, State#state{tagged_sub_requests = NewTagged}};
            error ->
                {{value, C}, NewAnon} = queue:out(Anon),
                {C, State#state{anon_sub_requests = NewAnon}}
        end,
    Consumer ! ConsumeOk,
    State1 = register_consumer(ConsumerTag, Consumer, State0),
    {noreply, rpc_bottom_half(ConsumeOk, State1)};
handle_method1(#'basic.cancel_ok'{consumer_tag = ConsumerTag} = CancelOk, none,
               State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! CancelOk,
    NewState = unregister_consumer(ConsumerTag, State),
    {noreply, rpc_bottom_half(CancelOk, NewState)};
handle_method1(#'channel.flow'{active = Active} = Flow, none,
               State = #state{flow_handler_pid = FlowHandler}) ->
    case FlowHandler of none -> ok;
                        _    -> FlowHandler ! Flow
    end,
    %% Putting the flow_ok in the queue so that the RPC queue can be
    %% flushed beforehand. Methods that made it to the queue are not
    %% blocked in any circumstance.
    {noreply, rpc_top_half(#'channel.flow_ok'{active = Active}, none, none,
                           State#state{flow_active = Active})};
handle_method1(#'basic.deliver'{consumer_tag = ConsumerTag} = Deliver, AmqpMsg,
               State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! {Deliver, AmqpMsg},
    {noreply, State};
handle_method1(#'basic.return'{} = BasicReturn, AmqpMsg,
               State = #state{return_handler_pid = ReturnHandler}) ->
    case ReturnHandler of
        none -> ?LOG_WARN("Channel (~p): received {~p, ~p} but there is no "
                          "return handler registered~n",
                          [self(), BasicReturn, AmqpMsg]);
        _    -> ReturnHandler ! {BasicReturn, AmqpMsg}
    end,
    {noreply, State};
handle_method1(#'basic.ack'{} = BasicAck, AmqpMsg,
               #state{ack_handler_pid = AckHandler} = State) ->
    case AckHandler of
        none -> ?LOG_WARN("Channel (~p): received {~p, ~p} but there is no "
                          "ack handler registered~n",
                          [self(), BasicAck, AmqpMsg]);
        _    -> AckHandler ! {BasicAck, AmqpMsg}
    end,
    {noreply, State};
handle_method1(Method, none, State) ->
    {noreply, rpc_bottom_half(Method, State)};
handle_method1(Method, Content, State) ->
    {noreply, rpc_bottom_half({Method, Content}, State)}.

%%---------------------------------------------------------------------------
%% Internal interface
%%---------------------------------------------------------------------------

%% @private
start_link(Driver, ChannelNumber, SWF) ->
    gen_server:start_link(?MODULE, [self(), Driver, ChannelNumber, SWF], []).

%% @private
connection_closing(Pid, ChannelCloseType) ->
    gen_server:cast(Pid, {connection_closing, ChannelCloseType}).

%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------

%% @private
init([Sup, Driver, ChannelNumber, SWF]) ->
    {ok, #state{sup              = Sup,
                driver           = Driver,
                number           = ChannelNumber,
                start_writer_fun = SWF}}.

%% Standard implementation of the call/{2,3} command
%% @private
handle_call({call, Method, AmqpMsg}, From, State) ->
    handle_method_call(Method, AmqpMsg, From, State);

%% Standard implementation of the subscribe/3 command
%% @private
handle_call({subscribe, #'basic.consume'{consumer_tag = Tag} = Method, Consumer},
            From, State = #state{tagged_sub_requests = Tagged,
                                 anon_sub_requests   = Anon}) ->
    case check_block(Method, none, State) of
        ok ->
            {NewMethod, NewState} =
                if Tag =:= undefined orelse size(Tag) == 0 ->
                       NewAnon = queue:in(Consumer, Anon),
                       {Method#'basic.consume'{consumer_tag = <<"">>},
                        State#state{anon_sub_requests = NewAnon}};
                   is_binary(Tag) ->
                       %% TODO test whether this tag already exists, either in
                       %% the pending tagged request map or in general as
                       %% already subscribed consumer
                       NewTagged = dict:store(Tag, Consumer, Tagged),
                       {Method, State#state{tagged_sub_requests = NewTagged}}
                end,
            {noreply, rpc_top_half(NewMethod, none, From, NewState)};
        BlockReply ->
            {reply, BlockReply, State}
    end;

%% These handle the delivery of messages from a direct channel
%% @private
handle_call({send_command_sync, Method, Content}, From, State) ->
    Ret = handle_method(Method, Content, State),
    gen_server:reply(From, ok),
    Ret;
%% @private
handle_call({send_command_sync, Method}, From, State) ->
    Ret = handle_method(Method, none, State),
    gen_server:reply(From, ok),
    Ret;

%% Get the number of published messages since the channel was put in
%% confirm mode.
%% @private
handle_call(get_published_message_count, _From,
            State = #state { pub_msg_count = PMC }) ->
    {reply, PMC, State}.

%% Standard implementation of the cast/{2,3} command
%% @private
handle_cast({cast, Method, AmqpMsg}, State) ->
    handle_method_call(Method, AmqpMsg, none, State);

%% Registers a handler to process return messages
%% @private
handle_cast({register_return_handler, ReturnHandler}, State) ->
    erlang:monitor(process, ReturnHandler),
    {noreply, State#state{return_handler_pid = ReturnHandler}};

%% Registers a handler to process ack messages
%% @private
handle_cast({register_ack_handler, AckHandler}, State) ->
    link(AckHandler),
    {noreply, State#state{ack_handler_pid = AckHandler}};

%% Registers a handler to process flow control messages
%% @private
handle_cast({register_flow_handler, FlowHandler}, State) ->
    erlang:monitor(process, FlowHandler),
    {noreply, State#state{flow_handler_pid = FlowHandler}};

%% Registers a handler to process unexpected deliveries
%% @private
handle_cast({register_default_consumer, Consumer}, State) ->
    erlang:monitor(process, Consumer),
    {noreply, State#state{default_consumer = Consumer}};

%% @private
handle_cast({notify_sent, _Peer}, State) ->
    {noreply, State};

%% This callback is invoked when a network channel sends messages
%% to this gen_server instance
%% @private
handle_cast({method, Method, Content}, State) ->
    handle_method(Method, Content, State);

%% Handles the situation when the connection closes without closing the channel
%% beforehand. The channel must block all further RPCs,
%% flush the RPC queue (optional), and terminate
%% @private
handle_cast({connection_closing, CloseType},
            #state{rpc_requests = RpcQueue,
                   closing      = Closing} = State) ->
    case {CloseType, Closing, queue:is_empty(RpcQueue)} of
        {flush, false, false} ->
            erlang:send_after(?TIMEOUT_FLUSH, self(),
                              {shutdown, timed_out_flushing_channel,
                               connection_closing}),
            {noreply, State#state{closing = connection}};
        {flush, just_channel, false} ->
            erlang:send_after(?TIMEOUT_CLOSE_OK, self(),
                              {shutdown, timed_out_waiting_close_ok,
                               connection_closing}),
            {noreply, State#state{closing = connection}};
        _ ->
            {stop, connection_closing, State}
    end.

%% These callbacks are invoked when a direct channel sends messages
%% to this gen_server instance
%% @private
handle_info({send_command, Method}, State) ->
    handle_method(Method, none, State);
%% @private
handle_info({send_command, Method, Content}, State) ->
    handle_method(Method, Content, State);

%% These callbacks handles the delivery of a message from a direct channel
%% @private
handle_info({send_command_and_notify, Q, ChPid, Method}, State) ->
    handle_method(Method, none, State),
    rabbit_amqqueue:notify_sent(Q, ChPid),
    {noreply, State};
%% @private
handle_info({send_command_and_notify, Q, ChPid, Method, Content}, State) ->
    handle_method(Method, Content, State),
    rabbit_amqqueue:notify_sent(Q, ChPid),
    {noreply, State};

%% This comes from framing channel, the writer or rabbit_channel
%% @private
handle_info({channel_exit, _FrPidOrChNumber, Reason},
            State = #state{number = Number}) ->
    case Reason of
        %% Sent by rabbit_channel in the direct case
        #amqp_error{name = ErrorName, explanation = Expl} ->
            ?LOG_WARN("Channel ~p closing: server sent error ~p~n",
                      [Number, Reason]),
            {IsHard, Code, _} = ?PROTOCOL:lookup_amqp_exception(ErrorName),
            {stop, {if IsHard -> server_initiated_hard_close;
                       true   -> server_initiated_close
                    end, Code, Expl}, State};
        %% Unexpected death of a channel infrastructure process
        _ ->
            {stop, {infrastructure_died, Reason}, State}
    end;

%% @private
handle_info({shutdown, {_, 200, _}}, State) ->
    {stop, normal, State};
%% @private
handle_info({shutdown, Reason}, State) ->
    {stop, Reason, State};

%% @private
handle_info({shutdown, FailShutdownReason, connection_closing},
            #state{number = Number} = State) ->
    case FailShutdownReason of
        timed_out_flushing_channel ->
            ?LOG_WARN("Channel ~p closing: timed out flushing while connection "
                      "closing~n", [Number]);
        timed_out_waiting_close_ok ->
            ?LOG_WARN("Channel ~p closing: timed out waiting for "
                      "channel.close_ok while connection closing~n", [Number])
    end,
    {stop, FailShutdownReason, State};

%% @private
handle_info({'DOWN', _, process, Pid, Reason}, State) ->
    handle_down(Pid, Reason, State).

handle_down(ReturnHandler, Reason,
            State = #state{return_handler_pid = ReturnHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering return handler ~p because it died. "
              "Reason: ~p~n", [self(), ReturnHandler, Reason]),
    {noreply, State#state{return_handler_pid = none}};
handle_down(FlowHandler, Reason,
            State = #state{flow_handler_pid = FlowHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering flow handler ~p because it died. "
              "Reason: ~p~n", [self(), FlowHandler, Reason]),
    {noreply, State#state{flow_handler_pid = none}};
handle_down(DefaultConsumer, Reason,
            State = #state{default_consumer = DefaultConsumer}) ->
    ?LOG_WARN("Channel (~p): Unregistering default consumer ~p because it died."
              "Reason: ~p~n", [self(), DefaultConsumer, Reason]),
    {noreply, State#state{default_consumer = none}};
handle_down(Other, Reason, State) ->
    {stop, {unexpected_down, Other, Reason}, State}.

%% @private
terminate(Reason, #state{rpc_requests = RpcQueue}) ->
    case queue:is_empty(RpcQueue) of
        false -> ?LOG_WARN("Channel (~p): RPC queue was not empty on "
                           "terminate~n", [self()]),
                 case Reason of
                     normal -> exit(rpc_queue_not_empty_on_terminate);
                     _      -> ok
                 end;
        true  -> ok
    end.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.
