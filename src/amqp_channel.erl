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
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

%% @type close_reason(Type) = {shutdown, amqp_reason(Type)}.
%% @type amqp_reason(Type) = {Type, Code, Text}
%%      Code = non_neg_integer()
%%      Text = binary().
%% @doc This module encapsulates the client's view of an AMQP
%% channel. Each server side channel is represented by an amqp_channel
%% process on the client side. Channel processes are created using the
%% {@link amqp_connection} module. Channel processes are supervised
%% under amqp_client's supervision tree.<br/>
%% <br/>
%% In case of a failure or an AMQP error, the channel process exits with a
%% meaningful exit reason:<br/>
%% <br/>
%% <table>
%%   <tr>
%%     <td><strong>Cause</strong></td>
%%     <td><strong>Exit reason</strong></td>
%%   </tr>
%%   <tr>
%%     <td>Any reason, where Code would have been 200 otherwise</td>
%%     <td>```normal'''</td>
%%   </tr>
%%   <tr>
%%     <td>User application calls amqp_channel:close/3</td>
%%     <td>```close_reason(app_initiated_close)'''</td>
%%   </tr>
%%   <tr>
%%     <td>Server closes channel (soft error)</td>
%%     <td>```close_reason(server_initiated_close)'''</td>
%%   </tr>
%%   <tr>
%%     <td>Server misbehaved (did not follow protocol)</td>
%%     <td>```close_reason(server_misbehaved)'''</td>
%%   </tr>
%%   <tr>
%%     <td>Connection is closing (causing all channels to cleanup and
%%         close)</td>
%%     <td>```{shutdown, {connection_closing, amqp_reason(atom())}}'''</td>
%%   </tr>
%%   <tr>
%%     <td>Other error</td>
%%     <td>(various error reasons, causing more detailed logging)</td>
%%   </tr>
%% </table>
%% <br/>
%% See type definitions below.
-module(amqp_channel).

-include("amqp_client.hrl").

-behaviour(gen_server).

-export([start_link/4, connection_closing/3, open/1]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([call/2, call/3, cast/2, cast/3]).
-export([subscribe/3]).
-export([close/1, close/3]).
-export([register_return_handler/2, register_flow_handler/2,
         register_confirm_handler/2]).
-export([next_publish_seqno/1]).
-export([register_default_consumer/2]).

-define(TIMEOUT_FLUSH, 60000).
-define(TIMEOUT_CLOSE_OK, 3000).

-record(state, {number,
                connection,
                driver,
                rpc_requests        = queue:new(),
                anon_sub_requests   = queue:new(),
                tagged_sub_requests = dict:new(),
                closing             = false, %% false |
                                             %%   {just_channel, Reason} |
                                             %%   {connection, Reason}
                writer,
                return_handler_pid  = none,
                confirm_handler_pid = none,
                next_pub_seqno      = 0,
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
    try
        gen_server:call(Channel, {call, Method, none}, infinity)
    catch
        exit:{{shutdown, Reason}, _} -> % gen_server died during call
            {error, Reason}
    end.

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

%% @spec (Channel) -> ok | closing
%% where
%%      Channel = pid()
%% @doc Closes the channel, invokes
%% close(Channel, 200, &lt;&lt;"Goodbye"&gt;&gt;).
close(Channel) ->
    close(Channel, 200, <<"Goodbye">>).

%% @spec (Channel, Code, Text) -> ok | closing
%% where
%%      Channel = pid()
%%      Code = integer()
%%      Text = binary()
%% @doc Closes the channel, allowing the caller to supply a reply code and
%% text. If the channel is already closing, the atom 'closing' is returned.
close(Channel, Code, Text) ->
    gen_server:call(Channel, {close, Code, Text}, infinity).

%% @spec (Channel) -> integer()
%% where
%%      Channel = pid()
%% @doc When in confirm mode, returns the sequence number of the next
%% message to be published.
next_publish_seqno(Channel) ->
    gen_server:call(Channel, next_publish_seqno, infinity).

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

%% @spec (Channel, ConfirmHandler) -> ok
%% where
%%      Channel = pid()
%%      ConfirmHandler = pid()

%% @doc This registers a handler to deal with confirm-related
%% messages. The registered process will receive #basic.ack{} and
%% #basic.nack{} commands.
register_confirm_handler(Channel, ConfirmHandler) ->
    gen_server:cast(Channel, {register_confirm_handler, ConfirmHandler} ).

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
%% Internal interface
%%---------------------------------------------------------------------------

%% @private
start_link(Driver, Connection, ChannelNumber, SWF) ->
    gen_server:start_link(?MODULE,
                          [Driver, Connection, ChannelNumber, SWF], []).

%% @private
connection_closing(Pid, ChannelCloseType, Reason) ->
    gen_server:cast(Pid, {connection_closing, ChannelCloseType, Reason}).

%% @private
open(Pid) ->
    gen_server:call(Pid, open, infinity).

%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------

%% @private
init([Driver, Connection, ChannelNumber, SWF]) ->
    {ok, #state{connection       = Connection,
                driver           = Driver,
                number           = ChannelNumber,
                start_writer_fun = SWF}}.

%% @private
handle_call(open, From, State) ->
    {noreply, rpc_top_half(#'channel.open'{}, none, From, State)};
%% @private
handle_call({close, Code, Text}, From, State) ->
    handle_close(Code, Text, From, State);
%% @private
handle_call({call, Method, AmqpMsg}, From, State) ->
    handle_method_to_server(Method, AmqpMsg, From, State);
%% @private
handle_call({subscribe, Method, Consumer}, From, State) ->
    handle_subscribe(Method, Consumer, From, State);
%% Handles the delivery of messages from a direct channel
%% @private
handle_call({send_command_sync, Method, Content}, From, State) ->
    Ret = handle_method_from_server(Method, Content, State),
    gen_server:reply(From, ok),
    Ret;
%% Handles the delivery of messages from a direct channel
%% @private
handle_call({send_command_sync, Method}, From, State) ->
    Ret = handle_method_from_server(Method, none, State),
    gen_server:reply(From, ok),
    Ret;
%% When in confirm mode, returns the sequence number of the next
%% message to be published.
%% @private
handle_call(next_publish_seqno, _From,
            State = #state{next_pub_seqno = SeqNo}) ->
    {reply, SeqNo, State}.

%% @private
handle_cast({cast, Method, AmqpMsg}, State) ->
    handle_method_to_server(Method, AmqpMsg, none, State);
%% Registers a handler to process return messages
%% @private
handle_cast({register_return_handler, ReturnHandler}, State) ->
    erlang:monitor(process, ReturnHandler),
    {noreply, State#state{return_handler_pid = ReturnHandler}};
%% Registers a handler to process ack and nack messages
%% @private
handle_cast({register_confirm_handler, ConfirmHandler}, State) ->
    erlang:monitor(process, ConfirmHandler),
    {noreply, State#state{confirm_handler_pid = ConfirmHandler}};
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
%% Received from channels manager
%% @private
handle_cast({method, Method, Content}, State) ->
    handle_method_from_server(Method, Content, State);
%% Handles the situation when the connection closes without closing the channel
%% beforehand. The channel must block all further RPCs,
%% flush the RPC queue (optional), and terminate
%% @private
handle_cast({connection_closing, CloseType, Reason}, State) ->
    handle_connection_closing(CloseType, Reason, State);
%% @private
handle_cast({shutdown, Shutdown}, State) ->
    handle_shutdown(Shutdown, State).

%% Received from rabbit_channel in the direct case
%% @private
handle_info({send_command, Method}, State) ->
    handle_method_from_server(Method, none, State);
%% Received from rabbit_channel in the direct case
%% @private
handle_info({send_command, Method, Content}, State) ->
    handle_method_from_server(Method, Content, State);
%% Received from rabbit_channel in the direct case
%% @private
handle_info({send_command_and_notify, Q, ChPid, Method, Content}, State) ->
    handle_method_from_server(Method, Content, State),
    rabbit_amqqueue:notify_sent(Q, ChPid),
    {noreply, State};
%% This comes from the writer or rabbit_channel
%% @private
handle_info({channel_exit, _ChNumber, Reason}, State) ->
    handle_channel_exit(Reason, State);
%% This comes from rabbit_channel in the direct case
handle_info({channel_closing, ChPid}, State) ->
    ok = rabbit_channel:ready_for_close(ChPid),
    {noreply, State};
%% @private
handle_info(timed_out_flushing_channel, State) ->
    ?LOG_WARN("Channel (~p) closing: timed out flushing while "
              "connection closing~n", [self()]),
    {stop, timed_out_flushing_channel, State};
%% @private
handle_info(timed_out_waiting_close_ok, State) ->
    ?LOG_WARN("Channel (~p) closing: timed out waiting for "
              "channel.close_ok while connection closing~n", [self()]),
    {stop, timed_out_waiting_close_ok, State};
%% @private
handle_info({'DOWN', _, process, ReturnHandler, Reason},
            State = #state{return_handler_pid = ReturnHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering return handler ~p because it died. "
              "Reason: ~p~n", [self(), ReturnHandler, Reason]),
    {noreply, State#state{return_handler_pid = none}};
%% @private
handle_info({'DOWN', _, process, ConfirmHandler, Reason},
            State = #state{confirm_handler_pid = ConfirmHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering confirm handler ~p because it died. "
              "Reason: ~p~n", [self(), ConfirmHandler, Reason]),
    {noreply, State#state{confirm_handler_pid = none}};
%% @private
handle_info({'DOWN', _, process, FlowHandler, Reason},
            State = #state{flow_handler_pid = FlowHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering flow handler ~p because it died. "
              "Reason: ~p~n", [self(), FlowHandler, Reason]),
    {noreply, State#state{flow_handler_pid = none}};
%% @private
handle_info({'DOWN', _, process, DefaultConsumer, Reason},
            State = #state{default_consumer = DefaultConsumer}) ->
    ?LOG_WARN("Channel (~p): Unregistering default consumer ~p because it died."
              "Reason: ~p~n", [self(), DefaultConsumer, Reason]),
    {noreply, State#state{default_consumer = none}}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

%%---------------------------------------------------------------------------
%% RPC mechanism
%%---------------------------------------------------------------------------

handle_method_to_server(Method, AmqpMsg, From, State) ->
    case {check_invalid_method(Method), From,
          check_block(Method, AmqpMsg, State)} of
        {ok, _, ok} ->
            State1 = case {Method, State#state.next_pub_seqno} of
                         {#'confirm.select'{}, _} ->
                             State#state{next_pub_seqno = 1};
                         {#'basic.publish'{}, 0} ->
                             State;
                         {#'basic.publish'{}, SeqNo} ->
                             State#state{next_pub_seqno = SeqNo + 1};
                         _ ->
                             State
                     end,
            {noreply,
             rpc_top_half(Method, build_content(AmqpMsg), From, State1)};
        {ok, none, BlockReply} ->
            ?LOG_WARN("Channel (~p): discarding method ~p in cast.~n"
                      "Reason: ~p~n", [self(), Method, BlockReply]),
            {noreply, State};
        {ok, _, BlockReply} ->
            {reply, BlockReply, State};
        {{_, InvalidMethodMessage}, none, _} ->
            ?LOG_WARN("Channel (~p): ignoring cast of ~p method. " ++
                      InvalidMethodMessage ++ "~n", [self(), Method]),
            {noreply, State};
        {{InvalidMethodReply, _}, _, _} ->
            {reply, {error, InvalidMethodReply}, State}
    end.

handle_close(Code, Text, From, State) ->
    Close = #'channel.close'{reply_code = Code,
                             reply_text = Text,
                             class_id   = 0,
                             method_id  = 0},
    case check_block(Close, none, State) of
        ok         -> {noreply, rpc_top_half(Close, none, From, State)};
        BlockReply -> {reply, BlockReply, State}
    end.

handle_subscribe(#'basic.consume'{consumer_tag = Tag, nowait = NoWait} = Method,
                 Consumer,
                 From, State = #state{tagged_sub_requests = Tagged,
                                      anon_sub_requests   = Anon,
                                      consumers           = Consumers}) ->
    case check_block(Method, none, State) of
        ok when Tag =:= undefined orelse size(Tag) == 0 ->
            case NoWait of
                true ->
                    {reply, {error, command_invalid}, State};
                false ->
                    NewMethod = Method#'basic.consume'{consumer_tag = <<"">>},
                    NewState = State#state{anon_sub_requests =
                                               queue:in(Consumer, Anon)},
                    {noreply, rpc_top_half(NewMethod, none, From, NewState)}
            end;
        ok when is_binary(Tag) andalso size(Tag) >= 0 ->
            case dict:is_key(Tag, Tagged) orelse dict:is_key(Tag, Consumers) of
                true ->
                    {reply, {error, consumer_tag_already_in_use}, State};
                false when NoWait ->
                    NewState = register_consumer(Tag, Consumer, State),
                    {reply, ok, rpc_top_half(Method, none, none, NewState)};
                false ->
                    NewState = State#state{tagged_sub_requests =
                                             dict:store(Tag, Consumer, Tagged)},
                    {noreply, rpc_top_half(Method, none, From, NewState)}
            end;
        BlockReply ->
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
    case From of
        none -> ok;
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
                             {_, ok}   -> gen_server:reply(From, ok);
                             _         -> ok
                             %% Do not reply if error in do. Expecting
                             %% {channel_exit, ...}
                         end,
                         do_rpc(State1#state{rpc_requests = NewQ})
            end;
        {empty, NewQ} ->
            case Closing of
                {connection, Reason} ->
                    gen_server:cast(self(),
                                    {shutdown, {connection_closing, Reason}});
                _ ->
                    ok
            end,
            State#state{rpc_requests = NewQ}
    end.

pre_do(#'channel.open'{}, none, State) ->
    start_writer(State);
pre_do(#'channel.close'{reply_code = Code, reply_text = Text}, none,
       State) ->
    State#state{closing = {just_channel, {app_initiated_close, Code, Text}}};
pre_do(_, _, State) ->
    State.

%%---------------------------------------------------------------------------
%% Handling of methods from the server
%%---------------------------------------------------------------------------

handle_method_from_server(Method, Content, State = #state{closing = Closing}) ->
    case is_connection_method(Method) of
        true -> server_misbehaved(
                    #amqp_error{name        = command_invalid,
                                explanation = "connection method on "
                                              "non-zero channel",
                                method      = element(1, Method)},
                    State);
        false -> Drop = case {Closing, Method} of
                            {{just_channel, _}, #'channel.close'{}}    -> false;
                            {{just_channel, _}, #'channel.close_ok'{}} -> false;
                            {{just_channel, _}, _}                     -> true;
                            _                                          -> false
                        end,
                 if Drop -> ?LOG_INFO("Channel (~p): dropping method ~p from "
                                      "server because channel is closing~n",
                                      [self(), {Method, Content}]),
                            {noreply, State};
                    true -> handle_method_from_server1(Method,
                                                       amqp_msg(Content), State)
                 end
    end.

handle_method_from_server1(#'channel.open_ok'{}, none, State) ->
    {noreply, rpc_bottom_half(ok, State)};
handle_method_from_server1(ChannelClose = #'channel.close'{}, none,
                           State = #state{closing = {just_channel, _}}) ->
    %% Both client and server sent close at the same time. Don't shutdown yet,
    %% wait for close_ok.
    do(#'channel.close_ok'{}, none, State),
    erlang:send_after(?TIMEOUT_CLOSE_OK, self(), timed_out_waiting_close_ok),
    {noreply, State#state{closing = {just_channel, ChannelClose}}};
handle_method_from_server1(ChannelClose = #'channel.close'{}, none, State) ->
    do(#'channel.close_ok'{}, none, State),
    handle_shutdown(ChannelClose, State);
handle_method_from_server1(#'channel.close_ok'{}, none,
                           State = #state{closing = Closing}) ->
    case Closing of
        {just_channel, {app_initiated_close, _, _} = Reason} ->
            handle_shutdown(Reason, rpc_bottom_half(ok, State));
        {just_channel, #'channel.close'{} = Reason} ->
            handle_shutdown(Reason, rpc_bottom_half(closing, State));
        {connection, Reason} ->
            handle_shutdown({connection_closing, Reason}, State)
    end;
handle_method_from_server1(
        #'basic.consume_ok'{consumer_tag = ConsumerTag} = ConsumeOk,
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
handle_method_from_server1(
        #'basic.cancel_ok'{consumer_tag = ConsumerTag} = CancelOk, none,
        State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! CancelOk,
    NewState = unregister_consumer(ConsumerTag, State),
    {noreply, rpc_bottom_half(CancelOk, NewState)};
handle_method_from_server1(#'channel.flow'{active = Active} = Flow, none,
                           State = #state{flow_handler_pid = FlowHandler}) ->
    case FlowHandler of none -> ok;
                        _    -> FlowHandler ! Flow
    end,
    %% Putting the flow_ok in the queue so that the RPC queue can be
    %% flushed beforehand. Methods that made it to the queue are not
    %% blocked in any circumstance.
    {noreply, rpc_top_half(#'channel.flow_ok'{active = Active}, none, none,
                           State#state{flow_active = Active})};
handle_method_from_server1(
        #'basic.deliver'{consumer_tag = ConsumerTag} = Deliver, AmqpMsg,
        State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! {Deliver, AmqpMsg},
    {noreply, State};
handle_method_from_server1(
        #'basic.return'{} = BasicReturn, AmqpMsg,
        State = #state{return_handler_pid = ReturnHandler}) ->
    case ReturnHandler of
        none -> ?LOG_WARN("Channel (~p): received {~p, ~p} but there is no "
                          "return handler registered~n",
                          [self(), BasicReturn, AmqpMsg]);
        _    -> ReturnHandler ! {BasicReturn, AmqpMsg}
    end,
    {noreply, State};
handle_method_from_server1(#'basic.cancel'{consumer_tag = ConsumerTag} = Death,
                           none, State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! Death,
    NewState = unregister_consumer(ConsumerTag, State),
    {noreply, NewState};
handle_method_from_server1(#'basic.ack'{} = BasicAck, none,
                           #state{confirm_handler_pid = none} = State) ->
    ?LOG_WARN("Channel (~p): received ~p but there is no "
              "confirm handler registered~n", [self(), BasicAck]),
    {noreply, State};
handle_method_from_server1(#'basic.ack'{} = BasicAck, none,
                           #state{confirm_handler_pid = ConfirmHandler} = State) ->
    ConfirmHandler ! BasicAck,
    {noreply, State};
handle_method_from_server1(#'basic.nack'{} = BasicNack, none,
                           #state{confirm_handler_pid = none} = State) ->
    ?LOG_WARN("Channel (~p): received ~p but there is no "
              "confirm handler registered~n", [self(), BasicNack]),
    {noreply, State};
handle_method_from_server1(#'basic.nack'{} = BasicNack, none,
                           #state{confirm_handler_pid = ConfirmHandler} = State) ->
    ConfirmHandler ! BasicNack,
    {noreply, State};

handle_method_from_server1(Method, none, State) ->
    {noreply, rpc_bottom_half(Method, State)};
handle_method_from_server1(Method, Content, State) ->
    {noreply, rpc_bottom_half({Method, Content}, State)}.

%%---------------------------------------------------------------------------
%% Other handle_* functions
%%---------------------------------------------------------------------------

handle_connection_closing(CloseType, Reason,
                          State = #state{rpc_requests = RpcQueue,
                                         closing      = Closing}) ->
    NewState = State#state{closing = {connection, Reason}},
    case {CloseType, Closing, queue:is_empty(RpcQueue)} of
        {flush, false, false} ->
            erlang:send_after(?TIMEOUT_FLUSH, self(),
                              timed_out_flushing_channel),
            {noreply, NewState};
        {flush, {just_channel, _}, false} ->
            erlang:send_after(?TIMEOUT_CLOSE_OK, self(),
                              timed_out_waiting_close_ok),
            {noreply, NewState};
        _ ->
            handle_shutdown({connection_closing, Reason}, NewState)
    end.

handle_channel_exit(Reason, State = #state{connection = Connection}) ->
    case Reason of
        %% Sent by rabbit_channel in the direct case when the server
        %% sends a frame that annoys rabbit_command_assembler in some
        %% way.
        #amqp_error{name = ErrorName, explanation = Expl} ->
            ?LOG_WARN("Channel (~p) closing: server sent error ~p~n",
                      [self(), Reason]),
            {IsHard, Code, _} = ?PROTOCOL:lookup_amqp_exception(ErrorName),
            ReportedReason = #'connection.close'{reply_code = Code,
                                                 reply_text = Expl},
            handle_shutdown(
                if IsHard ->
                             amqp_gen_connection:hard_error_in_channel(
                                 Connection, self(), ReportedReason),
                             {connection_closing, ReportedReason};
                   true   -> ReportedReason
                end, State);
        %% Unexpected death of a channel infrastructure process
        _ ->
            {stop, {infrastructure_died, Reason}, State}
    end.

handle_shutdown({_, 200, _}, State) ->
    {stop, normal, State};
handle_shutdown({connection_closing, normal}, State) ->
    {stop, normal, State};
handle_shutdown({connection_closing, ConnectionClose}, State) ->
    {stop, {shutdown, ConnectionClose}, State};
handle_shutdown(Reason, State) ->
    {stop, {shutdown, Reason}, State}.

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

check_block(_Method, _AmqpMsg, #state{closing = {just_channel, _}}) ->
    closing;
check_block(_Method, _AmqpMsg, #state{closing = {connection, _}}) ->
    closing;
check_block(_Method, none, #state{}) ->
    ok;
check_block(_Method, #amqp_msg{}, #state{flow_active = false}) ->
    blocked;
check_block(_Method, _AmqpMsg, #state{}) ->
    ok.

check_invalid_method(#'channel.open'{}) ->
    {use_amqp_connection_module,
     "Use amqp_connection:open_channel/{1,2} instead"};
check_invalid_method(#'channel.close'{}) ->
    {use_close_function, "Use close/{1,3} instead"};
check_invalid_method(#'basic.consume'{}) ->
    {use_subscribe_function, "Use subscribe/3 instead"};
check_invalid_method(Method) ->
    case is_connection_method(Method) of
        true  -> {connection_methods_not_allowed,
                  "Sending connection methods is not allowed"};
        false -> ok
    end.

is_connection_method(Method) ->
    {ClassId, _} = ?PROTOCOL:method_id(element(1, Method)),
    ?PROTOCOL:lookup_class_name(ClassId) == connection.

server_misbehaved(#amqp_error{} = AmqpError, State = #state{number = Number}) ->
    case rabbit_binary_generator:map_exception(Number, AmqpError, ?PROTOCOL) of
        {0, _} ->
            handle_shutdown({server_misbehaved, AmqpError}, State);
        {_, Close} ->
            ?LOG_WARN("Channel (~p) flushing and closing due to soft "
                      "error caused by the server ~p~n", [self(), AmqpError]),
            Self = self(),
            spawn(fun () -> call(Self, Close) end),
            {noreply, State}
    end.
