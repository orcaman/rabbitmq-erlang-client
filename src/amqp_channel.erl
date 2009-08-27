%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is the RabbitMQ Erlang Client.
%%
%%   The Initial Developers of the Original Code are LShift Ltd.,
%%   Cohesive Financial Technologies LLC., and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd., Cohesive Financial
%%   Technologies LLC., and Rabbit Technologies Ltd. are Copyright (C)
%%   2007 LShift Ltd., Cohesive Financial Technologies LLC., and Rabbit
%%   Technologies Ltd.;
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): Ben Hood <0x6e6562@gmail.com>.
%%

%% @doc This module encapsulates the client's view of an AMQP channel. Each
%% server side channel is represented by an amqp_channel process on the client
%% side. Channel processes are created using the {@link amqp_connection} 
%% module, but channels are respsonsible for closing themselves. Channel
%% processes are linked to the connnection process from which they were
%% created.
-module(amqp_channel).

-include("amqp_client.hrl").

-behaviour(gen_server).

-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).
-export([call/2, call/3, cast/2, cast/3]).
-export([subscribe/3]).
-export([close/1, close/3]).
-export([register_direct_peer/2]).
-export([register_return_handler/2]).
-export([register_flow_handler/2]).

%% This diagram shows the interaction between the different component
%% processes in an AMQP client scenario.
%%
%%                             message* / reply*        +-------+
%%                            +----------------------   | queue |
%%                            |                         +-------+
%%                            |
%%                            |                          +-----+
%%                            v                          |     |
%%           request                     reply*          |     v
%% +------+  -------+  +--------------+  <------+  +----------------+
%% | User |         |  | amqp_channel |         |  | direct_channel |
%% +------+  <------+  +--------------+  -------+  +----------------+
%%           response /        |          request
%% cast/call         /         |
%%                  /          | message
%%                 /           v
%% +-------------+/       +----------+
%% | Pending RPC |        | Consumer |
%% +-------------+        +----------+
%%       |
%% [consumer tag --> consumer pid]
%%
%% These notifications are processed asynchronously via
%% handle_info/2 callbacks

%%---------------------------------------------------------------------------
%% Type Definitions
%%---------------------------------------------------------------------------

%% @type amqp_command().
%% This abstract datatype represents the set of commands that comprise the
%% AMQP execution model. As indicated in the overview, the attributes of each 
%% commands in the execution model are described in the protocol
%% documentation. The Erlang record definitions are autogenerated from a
%% parseable version of the specification.

%% @type content() = #'basic.publish'{} | 
%%                   #'basic.deliver'{} |
%%                   #'basic.return'{}.
%% These are the content bearing AMQP commands.

%%---------------------------------------------------------------------------
%% AMQP Channel API methods
%%---------------------------------------------------------------------------

%% @spec (Channel, amqp_command()) -> amqp_command()
%% where
%%      Channel = pid()
%% @doc This is a generic RPC mechanism that sends an AMQP command and
%% receives an AMQP command as a response. This function blocks until the
%% response is returned.
call(Channel, Method) ->
    gen_server:call(Channel, {call, Method}, infinity).

%% @spec (Channel, amqp_command(), content()) -> ok | blocked
%% where
%%      Channel = pid()
%% @doc This sends an AMQP command with content and waits for a synchronous
%% response. Generally this is used with the #basic.publish{} command.
%% This will return a blocked atom if either the server has throttled the
%% client for flow control reasons or if the channel is shutting down due to a
%% broker initiated close.
%% Note that the synchronicity only means that the client has transmitted the
%% command to the broker. It does not imply that the broker has accepted
%% responsibility for the message. To acheive guaranteed delivery, this
%% function would have to be called within the context of a transaction.
call(Channel, Method, Content) ->
    gen_server:call(Channel, {call, Method, Content}, infinity).

%% @spec (Channel, amqp_command()) -> ok
%% @doc Asynchronous variant of {@link call/2}
cast(Channel, Method) ->
    gen_server:cast(Channel, {cast, Method}).
    
%% @spec (Channel, amqp_command(), content()) -> ok
%% @doc Asynchronous variant of {@link call/3}
cast(Channel, Method, Content) ->
    gen_server:cast(Channel, {cast, Method, Content}).

%% @spec (Channel) -> ok
%% where
%%      Channel = pid()
%% @doc Closes the channel, invokes close(Channel, 200, &lt;&lt;"Goodbye">>).
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
    Close = #'channel.close'{reply_text =  Text,
                             reply_code = Code,
                             class_id   = 0,
                             method_id  = 0},
    #'channel.close_ok'{} = call(Channel, Close),
    ok.
%%---------------------------------------------------------------------------
%% Consumer registration
%%---------------------------------------------------------------------------

%% @type consume() = #'basic.consume'{}.
%% The AMQP command that is used to  subscribe a consumer to a queue.
%% @spec (Channel, consume(), Consumer) -> amqp_command()
%% where
%%      Channel = pid()
%%      Consumer = pid()
%% @doc Creates a subscription to a queue. This subscribes a consumer pid to 
%% the queue defined in the #'basic.consume'{} command record. Note that both
%% both the process invoking this method and the supplied consumer process
%% receive an acknowledgement of the subscription. The calling process will
%% receive the acknowledgement as the return value of this function, whereas
%% the consumer process will receive the notification asynchronously.
subscribe(Channel, BasicConsume = #'basic.consume'{}, Consumer) ->
    gen_server:call(Channel, {BasicConsume, Consumer}, infinity).

%% @spec (Channel, ReturnHandler) -> ok
%% where
%%      Channel = pid()
%%      ReturnHandler = pid()
%% @doc This registers a handler to deal with returned messages. The 
%% registered process will receive #basic.return{} commands.
register_return_handler(Channel, ReturnHandler) ->
    gen_server:cast(Channel, {register_return_handler, ReturnHandler} ).

%% @spec (Channel, FlowHandler) -> ok
%% where
%%      Channel = pid()
%%      FlowHandler = pid()
%% @doc This registers a handler to deal with channel flow notifications.
%% The registered process will receive #channel.flow{} commands.
register_flow_handler(Channel, FlowHandler) ->
    gen_server:cast(Channel, {register_flow_handler, FlowHandler} ).

%%---------------------------------------------------------------------------
%% Direct peer registration
%%---------------------------------------------------------------------------

%% @private
%% Registers the direct channel peer with the state of this channel.
%% This registration occurs after the amqp_channel gen_server instance
%% because the pid of this amqp_channel needs to be passed into the
%% initialization of that direct channel process, hence the resulting
%% direct channel pid can only be post-registered.
%% Have another look at this: This is also being used to register a writer
%% pid in the network case as well.........code reuse ;-)
register_direct_peer(Channel, Peer) ->
    gen_server:cast(Channel, {register_direct_peer, Peer} ).

%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

rpc_top_half(Method, From, State) ->
    rpc_top_half(Method, undefined, From, State).

rpc_top_half(Method, Content, From, 
             State = #channel_state{writer_pid = Writer,
                                    rpc_requests = RequestQueue,
                                    do2 = Do2,
                                    do3 = Do3}) ->
    % Enqueue the incoming RPC request to serialize RPC dispatching
    NewRequestQueue = queue:in({From, Method}, RequestQueue),
    NewState = State#channel_state{rpc_requests = NewRequestQueue},
    case queue:len(NewRequestQueue) of
        1 ->
            case Content of
                undefined -> Do2(Writer, Method);
                _         -> Do3(writer, Method, Content)
            end;
        _ ->
            ok
        end,
    {noreply, NewState}.

rpc_bottom_half(Reply, State = #channel_state{writer_pid = Writer,
                                              rpc_requests = RequestQueue,
                                              do2 = Do2}) ->
    NewRequestQueue =
        case queue:out(RequestQueue) of
            {empty, _}              -> exit(empty_rpc_bottom_half);
            {{value, {From, _}}, Q} -> gen_server:reply(From, Reply),
                                       Q
        end,
    case queue:is_empty(NewRequestQueue) of
        true  -> ok;
        false -> {_NewFrom, Method} = queue:head(NewRequestQueue),
                 Do2(Writer, Method)
    end,
    {noreply, State#channel_state{rpc_requests = NewRequestQueue}}.


resolve_consumer(_ConsumerTag, #channel_state{consumers = []}) ->
    exit(no_consumers_registered);

resolve_consumer(ConsumerTag, #channel_state{consumers = Consumers}) ->
    dict:fetch(ConsumerTag, Consumers).

register_consumer(ConsumerTag, Consumer,
                  State = #channel_state{consumers = Consumers0}) ->
    Consumers1 = dict:store(ConsumerTag, Consumer, Consumers0),
    State#channel_state{consumers = Consumers1}.

unregister_consumer(ConsumerTag,
                    State = #channel_state{consumers = Consumers0}) ->
    Consumers1 = dict:erase(ConsumerTag, Consumers0),
    State#channel_state{consumers = Consumers1}.

shutdown_writer(State = #channel_state{close_fun = CloseFun,
                                       writer_pid = WriterPid}) ->
    CloseFun(WriterPid),
    State.

channel_cleanup(State = #channel_state{consumers = []}) ->
    shutdown_writer(State);

channel_cleanup(State = #channel_state{consumers = Consumers}) ->
    Terminator = fun(_ConsumerTag, Consumer) -> Consumer ! shutdown end,
    dict:map(Terminator, Consumers),
    NewState = State#channel_state{closing = true, consumers = []},
    shutdown_writer(NewState).

return_handler(State = #channel_state{return_handler_pid = undefined}) ->
    %% TODO what about trapping exits??
    {ok, ReturnHandler} = gen_event:start_link(),
    gen_event:add_handler(ReturnHandler, amqp_return_handler , [] ),
    {ReturnHandler, State#channel_state{return_handler_pid = ReturnHandler}};

return_handler(State = #channel_state{return_handler_pid = ReturnHandler}) ->
    {ReturnHandler, State}.

amqp_msg(Content) ->
    {Props, Payload} = rabbit_basic:from_content(Content),
    #amqp_msg{props = Props, payload = Payload}.

handle_method(ConsumeOk = #'basic.consume_ok'{consumer_tag = ConsumerTag},
              State = #channel_state{anon_sub_requests = Anon,
                                     tagged_sub_requests = Tagged}) ->
    {_From, Consumer, State0} =
        case dict:find(ConsumerTag, Tagged) of
            {ok, {F,C}} ->
                NewTagged = dict:erase(ConsumerTag,Tagged),
                {F,C,State#channel_state{tagged_sub_requests = NewTagged}};
            error ->
                case queue:out(Anon) of
                    {empty, _} ->
                        exit({anonymous_queue_empty, ConsumerTag});
                    {{value, {F, C}}, NewAnon} ->
                        {F, C,
                         State#channel_state{anon_sub_requests = NewAnon}}
                end
        end,
    Consumer ! ConsumeOk,
    State1 = register_consumer(ConsumerTag, Consumer, State0),
    rpc_bottom_half(ConsumeOk, State1);

handle_method(CancelOk = #'basic.cancel_ok'{consumer_tag = ConsumerTag},
              State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! CancelOk,
    NewState = unregister_consumer(ConsumerTag, State),
    rpc_bottom_half(CancelOk, NewState);

handle_method(CloseOk = #'channel.close_ok'{}, State) ->
    {noreply, NewState} = rpc_bottom_half(CloseOk, State),
    {stop, normal, NewState};

%% Handles the scenario when the broker intiates a channel.close
handle_method(#'channel.close'{reply_code = ReplyCode,
                               reply_text = ReplyText},
              State = #channel_state{do2 = Do2,
                                     writer_pid = Writer}) ->
    Do2(Writer, #'channel.close_ok'{}),
    {stop, {server_initiated_close, ReplyCode, ReplyText}, State};

%% This handles the flow control flag that the broker initiates.
%% If defined, it informs the flow control handler to suspend submitting
%% any content bearing methods
handle_method(Flow = #'channel.flow'{active = Active},
              State = #channel_state{writer_pid = Writer,
                                     do2 = Do2,
                                     flow_handler_pid = FlowHandler}) ->
    case FlowHandler of
        undefined -> ok;
        _ -> FlowHandler ! Flow
    end,
    Do2(Writer, #'channel.flow_ok'{active = Active}),
    {noreply, State#channel_state{flow_control = not(Active)}};

handle_method(Method, State) ->
    rpc_bottom_half(Method, State).

handle_method(Deliver = #'basic.deliver'{consumer_tag = ConsumerTag},
              Content, State) ->
    Consumer = resolve_consumer(ConsumerTag, State),
    Consumer ! {Deliver, amqp_msg(Content)},
    {noreply, State};

%% Why is the consumer a handle_method/3 call with the network driver,
%% but this is a handle_method/2 call with the direct driver?
handle_method('basic.consume_ok', ConsumerTag, State) ->
    handle_method(#'basic.consume_ok'{consumer_tag = ConsumerTag}, State);

handle_method(BasicReturn = #'basic.return'{}, Content, State) ->
    {ReturnHandler, NewState} = return_handler(State),
    ReturnHandler ! {BasicReturn, amqp_msg(Content)},
    {noreply, NewState};

handle_method(Method, Content, State) ->
    rpc_bottom_half( {Method, amqp_msg(Content)} , State).

%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------
%% @private
init([InitialState]) ->
    {ok, InitialState}.

%% Standard implementation of top half of the call/2 command
%% Do not accept any further RPCs when the channel is about to close
%% @private
handle_call({call, Method}, From, State = #channel_state{closing    = false,
                                                         writer_pid = Writer,
                                                         do2 = Do2}) ->
    case rabbit_framing:is_method_synchronous(Method) of
        true  -> rpc_top_half(Method, From, State);
        false -> Do2(Writer, Method), {reply, ok, State}
    end;

%% @private
handle_call({call, _Method, _Content}, _From,
            State = #channel_state{flow_control = true}) ->
    {reply, blocked, State};

%% Do not accept any further messages for writer when the channel is about to
%% close
%% @private
handle_call({call, _Method, _Content}, _From,
            State = #channel_state{closing = true}) ->
    {reply, blocked, State};

%% @private
handle_call({call, Method, #amqp_msg{props = Props, payload = Payload}},
            From, State = #channel_state{writer_pid = Writer, do3 = Do3}) ->
    Content = rabbit_basic:build_content(Props, Payload),
    case rabbit_framing:is_method_synchronous(Method) of
        true  -> rpc_top_half(Method, Content, From, State);
        false -> 
			Do3(Writer, Method, Content),
			{reply, ok, State}
    end;

%% Top half of the basic consume process.
%% Sets up the consumer for registration in the bottom half of this RPC.
%% @private
handle_call({Method = #'basic.consume'{consumer_tag = Tag}, Consumer},
            From, State = #channel_state{anon_sub_requests = Subs})
            when Tag =:= undefined ; size(Tag) == 0 ->
    NewSubs = queue:in({From,Consumer}, Subs),
    NewState = State#channel_state{anon_sub_requests = NewSubs},
    NewMethod =  Method#'basic.consume'{consumer_tag = <<"">>},
    rpc_top_half(NewMethod, From, NewState);

%% @private
handle_call({Method = #'basic.consume'{consumer_tag = Tag}, Consumer},
            From, State = #channel_state{tagged_sub_requests = Subs})
            when is_binary(Tag) ->
    % TODO test whether this tag already exists, either in the pending tagged
    % request map or in general as already subscribed consumer
    NewSubs = dict:store(Tag,{From,Consumer},Subs),
    NewState = State#channel_state{tagged_sub_requests = NewSubs},
    rpc_top_half(Method, From, NewState).

%% Do not accept any further messages for writer when the channel is about to
%% close
%% @private
handle_cast({cast, _Method}, State = #channel_state{closing = true}) ->
    {noreply, State};

%% Standard implementation of the cast/2 command
%% @private
handle_cast({cast, Method}, State = #channel_state{writer_pid = Writer,
                                                   do2 = Do2}) ->
    Do2(Writer, Method),
    {noreply, State};

%% This discards any message submitted to the channel when flow control is
%% active
%% @private
handle_cast({cast, Method, _Content},
            State = #channel_state{flow_control = true}) ->
    % Discard the message and log it
    ?LOG_INFO("Discarding content bearing method (~p) ~n", [Method]),
    {noreply, State};

%% Do not accept any further messages for writer when the channel is about to
%% close
%% @private
handle_cast({cast, _Method, _Content}, State = #channel_state{closing = true}) ->
    {noreply, State};

%% Standard implementation of the cast/3 command
%% @private
handle_cast({cast, Method, #amqp_msg{props = Props, payload = Payload}},
            State = #channel_state{writer_pid = Writer, do3 = Do3}) ->
    Do3(Writer, Method, rabbit_basic:build_content(Props, Payload)),
    {noreply, State};

%% Registers the direct channel peer when using the direct client
%% @private
handle_cast({register_direct_peer, Peer}, State) ->
    link(Peer),
    process_flag(trap_exit, true),
    NewState = State#channel_state{writer_pid = Peer},
    {noreply, NewState};

%% Registers a handler to process return messages
%% @private
handle_cast({register_return_handler, ReturnHandler}, State) ->
    NewState = State#channel_state{return_handler_pid = ReturnHandler},
    {noreply, NewState};

%% Registers a handler to process flow control messages
%% @private
handle_cast({register_flow_handler, FlowHandler}, State) ->
    NewState = State#channel_state{flow_handler_pid = FlowHandler},
    {noreply, NewState};

%% @private
handle_cast({notify_sent, _Peer}, State) ->
    {noreply, State};

%%---------------------------------------------------------------------------
%% Network Writer methods (gen_server callbacks).
%% These callbacks are invoked when a network channel sends messages
%% to this gen_server instance.
%%---------------------------------------------------------------------------

%% @private
handle_cast( {method, Method, none}, State) ->
    handle_method(Method, State);

%% @private
handle_cast( {method, Method, Content}, State) ->
    handle_method(Method, Content, State).

%%---------------------------------------------------------------------------
%% Rabbit Writer API methods (gen_server callbacks).
%% These callbacks are invoked when a direct channel sends messages
%% to this gen_server instance.
%%---------------------------------------------------------------------------

%% @private
handle_info( {send_command, Method}, State) ->
    handle_method(Method, State);

%% @private
handle_info( {send_command, Method, Content}, State) ->
    handle_method(Method, Content, State);

%% @private
handle_info(shutdown, State) ->
    NewState = channel_cleanup(State),
    {stop, normal, NewState};

%% Handles the delivery of a message from a direct channel
%% @private
handle_info( {send_command_and_notify, Q, ChPid, Method, Content}, State) ->
    handle_method(Method, Content, State),
    rabbit_amqqueue:notify_sent(Q, ChPid),
    {noreply, State};


%% Handle a trapped exit, e.g. from the direct peer
%% In the direct case this is the local channel
%% In the network case this is the process that writes to the socket
%% on a per channel basis
%% @private
handle_info({'EXIT', _Pid, Reason},
            State = #channel_state{number = Number}) ->
    ?LOG_WARN("Channel ~p is shutting down due to: ~p~n",[Number, Reason]),
    {stop, normal, State};

%% This is for a channel exception that can't be otherwise handled
%% @private
handle_info( {channel_exit, _Channel, Reason}, State) ->
   {stop, Reason, State}.

%%---------------------------------------------------------------------------
%% Rest of the gen_server callbacks
%%---------------------------------------------------------------------------

%% @private
terminate(_Reason, State) ->
    channel_cleanup(State),
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

