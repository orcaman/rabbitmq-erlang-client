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

%% @private
-module(amqp_network_connection).

-include("amqp_client.hrl").

-behaviour(amqp_gen_connection).

-export([init/1, terminate/2, connect/4, do/2, open_channel_args/1, i/2,
         info_keys/0, handle_message/2, closing/3, channels_terminated/1]).

-define(RABBIT_TCP_OPTS, [binary, {packet, 0}, {active,false}, {nodelay, true}]).
-define(SOCKET_CLOSING_TIMEOUT, 1000).
-define(HANDSHAKE_RECEIVE_TIMEOUT, 60000).

-record(state, {sock,
                heartbeat,
                writer0,
                frame_max,
                closing_reason, %% undefined | Reason
                waiting_socket_close = false}).

-define(INFO_KEYS, [type, heartbeat, frame_max, sock]).

%%---------------------------------------------------------------------------

init([]) ->
    {ok, #state{}}.

open_channel_args(#state{sock = Sock}) ->
    [Sock].

do(#'connection.close_ok'{} = CloseOk, State) ->
    erlang:send_after(?SOCKET_CLOSING_TIMEOUT, self(), socket_closing_timeout),
    do2(CloseOk, State);
do(Method, State) ->
    do2(Method, State).

do2(Method, #state{writer0 = Writer}) ->
    %% Catching because it expects the {channel_exit, _, _} message on error
    catch rabbit_writer:send_command_sync(Writer, Method).

handle_message(timeout_waiting_for_close_ok,
               State = #state{closing_reason = Reason}) ->
    {stop, {timeout_waiting_for_close_ok, Reason}, State};
handle_message(socket_closing_timeout,
               State = #state{closing_reason = Reason}) ->
    {stop, {socket_closing_timeout, Reason}, State};
handle_message(socket_closed, State = #state{waiting_socket_close = true,
                                             closing_reason = Reason}) ->
    {stop, Reason, State};
handle_message(socket_closed, State = #state{waiting_socket_close = false}) ->
    {stop, socket_closed_unexpectedly, State};
handle_message({socket_error, _} = SocketError, State) ->
    {stop, SocketError, State};
handle_message({channel_exit, _, Reason}, State) ->
    {stop, {channel0_died, Reason}, State};
handle_message(heartbeat_timeout, State) ->
    {stop, heartbeat_timeout, State}.

closing(_ChannelCloseType, Reason, State) ->
    {ok, State#state{closing_reason = Reason}}.

channels_terminated(State = #state{closing_reason =
                                     {server_initiated_close, _, _}}) ->
    {ok, State#state{waiting_socket_close = true}};
channels_terminated(State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

i(type,     _State) -> network;
i(heartbeat, State) -> State#state.heartbeat;
i(frame_max, State) -> State#state.frame_max;
i(sock,      State) -> State#state.sock;
i(Item,     _State) -> throw({bad_argument, Item}).

info_keys() ->
    ?INFO_KEYS.

%%---------------------------------------------------------------------------
%% Handshake
%%---------------------------------------------------------------------------

connect(AmqpParams = #amqp_params{ssl_options = none,
                                  host        = Host,
                                  port        = Port}, SIF, ChMgr, State) ->
    case gen_tcp:connect(Host, Port, ?RABBIT_TCP_OPTS) of
        {ok, Sock}     -> try_handshake(AmqpParams, SIF, ChMgr,
                                        State#state{sock = Sock});
        {error, _} = E -> E
    end;
connect(AmqpParams = #amqp_params{ssl_options = SslOpts,
                                  host        = Host,
                                  port        = Port}, SIF, ChMgr, State) ->
    rabbit_misc:start_applications([crypto, public_key, ssl]),
    case gen_tcp:connect(Host, Port, ?RABBIT_TCP_OPTS) of
        {ok, Sock} ->
            case ssl:connect(Sock, SslOpts) of
                {ok, SslSock} ->
                    RabbitSslSock = #ssl_socket{ssl = SslSock, tcp = Sock},
                    try_handshake(AmqpParams, SIF, ChMgr,
                                  State#state{sock = RabbitSslSock});
                {error, _} = E ->
                    E
            end;
        {error, _} = E ->
            E
    end.

try_handshake(AmqpParams, SIF, ChMgr, State) ->
    try handshake(AmqpParams, SIF, ChMgr, State) of
        Return -> Return
    catch _:Reason -> {error, Reason}
    end.

handshake(AmqpParams, SIF, ChMgr, State0 = #state{sock = Sock}) ->
    ok = rabbit_net:send(Sock, ?PROTOCOL_HEADER),
    {SHF, State1} = start_infrastructure(SIF, ChMgr, State0),
    network_handshake(AmqpParams, SHF, State1).

start_infrastructure(SIF, ChMgr, State = #state{sock = Sock}) ->
    {ok, {_MainReader, _Framing, Writer, SHF}} = SIF(Sock, ChMgr),
    {SHF, State#state{writer0 = Writer}}.

network_handshake(AmqpParams, SHF, State0) ->
    Start = #'connection.start'{server_properties = ServerProperties} =
        handshake_recv(expecting_start),
    ok = check_version(Start),
    do2(start_ok(AmqpParams), State0),
    Tune = handshake_recv(expecting_tune),
    {TuneOk, ChannelMax, State1} = tune(Tune, AmqpParams, SHF, State0),
    do2(TuneOk, State1),
    do2(#'connection.open'{virtual_host = AmqpParams#amqp_params.virtual_host},
        State1),
    Params = {ServerProperties, ChannelMax, State1},
    case handshake_recv(expecting_open_ok) of
        #'connection.open_ok'{}                     -> {ok, Params};
        {closing, #amqp_error{} = AmqpError, Error} -> {closing, Params,
                                                        AmqpError, Error}
    end.

check_version(#'connection.start'{version_major = ?PROTOCOL_VERSION_MAJOR,
                                  version_minor = ?PROTOCOL_VERSION_MINOR}) ->
    ok;
check_version(#'connection.start'{version_major = 8,
                                  version_minor = 0}) ->
    exit({protocol_version_mismatch, 0, 8});
check_version(#'connection.start'{version_major = Major,
                                  version_minor = Minor}) ->
    exit({protocol_version_mismatch, Major, Minor}).

tune(#'connection.tune'{channel_max = ServerChannelMax,
                        frame_max   = ServerFrameMax,
                        heartbeat   = ServerHeartbeat},
     #amqp_params{channel_max = ClientChannelMax,
                  frame_max   = ClientFrameMax,
                  heartbeat   = ClientHeartbeat}, SHF, State) ->
    [ChannelMax, Heartbeat, FrameMax] =
        lists:zipwith(fun (Client, Server) when Client =:= 0; Server =:= 0 ->
                              lists:max([Client, Server]);
                          (Client, Server) ->
                              lists:min([Client, Server])
                      end, [ClientChannelMax, ClientHeartbeat, ClientFrameMax],
                           [ServerChannelMax, ServerHeartbeat, ServerFrameMax]),
    NewState = State#state{heartbeat = Heartbeat, frame_max = FrameMax},
    start_heartbeat(SHF, NewState),
    {#'connection.tune_ok'{channel_max = ChannelMax,
                           frame_max   = FrameMax,
                           heartbeat   = Heartbeat}, ChannelMax, NewState}.

start_heartbeat(SHF, #state{sock = Sock, heartbeat = Heartbeat}) ->
    SendFun = fun () -> Frame = rabbit_binary_generator:build_heartbeat_frame(),
                        catch rabbit_net:send(Sock, Frame)
              end,
    Connection = self(),
    ReceiveFun = fun () -> Connection ! heartbeat_timeout end,
    SHF(Sock, Heartbeat, SendFun, Heartbeat, ReceiveFun).

start_ok(#amqp_params{username          = Username,
                      password          = Password,
                      client_properties = UserProps}) ->
    LoginTable = [{<<"LOGIN">>, longstr, Username},
                  {<<"PASSWORD">>, longstr, Password}],
    #'connection.start_ok'{
        client_properties = client_properties(UserProps),
        mechanism = <<"AMQPLAIN">>,
        response = rabbit_binary_generator:generate_table(LoginTable)}.

client_properties(UserProperties) ->
    {ok, Vsn} = application:get_key(amqp_client, vsn),
    Default = [{<<"product">>,   longstr, <<"RabbitMQ">>},
               {<<"version">>,   longstr, list_to_binary(Vsn)},
               {<<"platform">>,  longstr, <<"Erlang">>},
               {<<"copyright">>, longstr,
                <<"Copyright (C) 2007-2009 LShift Ltd., "
                  "Cohesive Financial Technologies LLC., "
                  "and Rabbit Technologies Ltd.">>},
               {<<"information">>, longstr,
                <<"Licensed under the MPL.  "
                  "See http://www.rabbitmq.com/">>}],
    lists:foldl(fun({K, _, _} = Tuple, Acc) ->
                    lists:keystore(K, 1, Acc, Tuple)
                end, Default, UserProperties).

handshake_recv(Phase) ->
    receive
        {'$gen_cast', {method, Method, none}} ->
            case {Phase, Method} of
                {expecting_start, #'connection.start'{}} ->
                    Method;
                {expecting_tune, #'connection.tune'{}} ->
                    Method;
                {expecting_open_ok, #'connection.open_ok'{}} ->
                    Method;
                {expecting_open_ok, _} ->
                    {closing,
                     #amqp_error{name        = command_invalid,
                                 explanation = "was expecting "
                                               "connection.open_ok"},
                     {error, {unexpected_method, Method, Phase}}};
                _ ->
                    exit({unexpected_method, Method, Phase})
            end;
        socket_closed ->
            case Phase of expecting_tune    -> exit(auth_failure);
                          expecting_open_ok -> exit(access_refused);
                          _                 -> exit({socket_closed_unexpectedly,
                                                     Phase})
            end;
        {socket_error, _} = SocketError ->
            exit({SocketError, Phase});
        heartbeat_timeout ->
            exit(heartbeat_timeout);
        Other ->
            exit({handshake_recv_unexpected_message, Other})
    after ?HANDSHAKE_RECEIVE_TIMEOUT ->
        case Phase of
            expecting_open_ok ->
                {closing,
                 #amqp_error{name        = internal_error,
                             explanation = "handshake timed out waiting "
                                           "connection.open_ok"},
                 {error, handshake_receive_timed_out}};
            _ ->
                exit(handshake_receive_timed_out)
        end
    end.
