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

-module(negative_test_util).

-include("amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

non_existent_exchange_test(Connection) ->
    X = test_util:uuid(),
    RoutingKey = <<"a">>,
    Payload = <<"foobar">>,
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {ok, OtherChannel} = amqp_connection:open_channel(Connection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = X}),

    %% Deliberately mix up the routingkey and exchange arguments
    Publish = #'basic.publish'{exchange = RoutingKey, routing_key = X},
    amqp_channel:call(Channel, Publish, #amqp_msg{payload = Payload}),
    test_util:wait_for_death(Channel),

    %% Make sure Connection and OtherChannel still serve us and are not dead
    {ok, _} = amqp_connection:open_channel(Connection),
    #'exchange.declare_ok'{} =
        amqp_channel:call(OtherChannel,
                          #'exchange.declare'{exchange = test_util:uuid()}),
    amqp_connection:close(Connection).

bogus_rpc_test(Connection) ->
    X = test_util:uuid(),
    Q = test_util:uuid(),
    R = test_util:uuid(),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = X}),
    %% Deliberately bind to a non-existent queue
    Bind = #'queue.bind'{exchange = X, queue = Q, routing_key = R},
    case amqp_channel:call(Channel, Bind) of
        {error, #'channel.close'{}} -> ok;
        _                           -> exit(expected_to_exit)
    end,
    test_util:wait_for_death(Channel),
    ?assertMatch(true, is_process_alive(Connection)),
    amqp_connection:close(Connection).

hard_error_test(Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {ok, OtherChannel} = amqp_connection:open_channel(Connection),
    OtherChannelMonitor = erlang:monitor(process, OtherChannel),
    Qos = #'basic.qos'{global = true},
    case amqp_channel:call(Channel, Qos) of
        %% Network case
        {error, #'connection.close'{reply_code = ?NOT_IMPLEMENTED}} -> ok;
        E -> exit({expected_to_exit_but_got, E})
    end,
    receive
        {'DOWN', OtherChannelMonitor, process, OtherChannel, OtherExit} ->
            ?assertMatch({shutdown,
                          #'connection.close'{reply_code = ?NOT_IMPLEMENTED}},
                         OtherExit)
    end,
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection).

%% An error in a channel should result in the death of the entire connection.
%% The death of the channel is caused by an error in generating the frames
%% (writer dies) - only in the network case
channel_writer_death_test(Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    Publish = #'basic.publish'{routing_key = <<>>, exchange = <<>>},
    Message = #amqp_msg{props = <<>>, payload = <<>>},
    ?assertExit(_, amqp_channel:call(Channel, Publish, Message)),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% An error in the channel process should result in the death of the entire
%% connection. The death of the channel is caused by making a call with an
%% invalid message to the channel process
channel_death_test(Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    ?assertExit(_, amqp_channel:call(Channel, bogus_message)),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% Attempting to send a shortstr longer than 255 bytes in a property field
%% should fail - this only applies to the network case
shortstr_overflow_property_test(Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    SentString = << <<"k">> || _ <- lists:seq(1, 340)>>,
    Q = test_util:uuid(), X = test_util:uuid(), Key = test_util:uuid(),
    Payload = <<"foobar">>,
    test_util:setup_exchange(Channel, Q, X, Key),
    Publish = #'basic.publish'{exchange = X, routing_key = Key},
    PBasic = #'P_basic'{content_type = SentString},
    AmqpMsg = #amqp_msg{payload = Payload, props = PBasic},
    ?assertExit(_, amqp_channel:call(Channel, Publish, AmqpMsg)),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% Attempting to send a shortstr longer than 255 bytes in a method's field
%% should fail - this only applies to the network case
shortstr_overflow_field_test(Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    SentString = << <<"k">> || _ <- lists:seq(1, 340)>>,
    Q = test_util:uuid(), X = test_util:uuid(), Key = test_util:uuid(),
    test_util:setup_exchange(Channel, Q, X, Key),
    ?assertExit(_, amqp_channel:subscribe(
                       Channel, #'basic.consume'{queue = Q, no_ack = true,
                                                 consumer_tag = SentString},
                       self())),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% Simulates a #'connection.open'{} method received on non-zero channel. The
%% connection is expected to send a '#connection.close{}' to the server with
%% reply code command_invalid
command_invalid_over_channel_test(Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    MonitorRef = erlang:monitor(process, Connection),
    case amqp_connection:info(Connection, [type]) of
        [{type, direct}]  -> Channel ! {send_command, #'connection.open'{}};
        [{type, network}] -> gen_server:cast(Channel,
                                 {method, #'connection.open'{}, none})
    end,
    assert_down_with_error(MonitorRef, command_invalid),
    ?assertNot(is_process_alive(Channel)),
    ok.

%% Simulates a #'basic.ack'{} method received on channel zero. The connection
%% is expected to send a '#connection.close{}' to the server with reply code
%% command_invalid - this only applies to the network case
command_invalid_over_channel0_test(Connection) ->
    gen_server:cast(Connection, {method, #'basic.ack'{}, none}),
    MonitorRef = erlang:monitor(process, Connection),
    assert_down_with_error(MonitorRef, command_invalid),
    ok.

assert_down_with_error(MonitorRef, CodeAtom) ->
    receive
        {'DOWN', MonitorRef, process, _, Reason} ->
            {shutdown, #'connection.close'{reply_code = Code}} = Reason,
            ?assertMatch(CodeAtom, ?PROTOCOL:amqp_exception(Code))
    after 2000 ->
        exit(did_not_die)
    end.

non_existent_user_test(StartConnectionFun) ->
    ?assertMatch({error, auth_failure}, StartConnectionFun(test_util:uuid(),
                                                           test_util:uuid(),
                                                           test_util:uuid())).

invalid_password_test(StartConnectionFun) ->
    ?assertMatch({error, auth_failure}, StartConnectionFun(<<"guest">>,
                                                           test_util:uuid(),
                                                           test_util:uuid())).

non_existent_vhost_test(StartConnectionFun) ->
    ?assertMatch({error, access_refused}, StartConnectionFun(<<"guest">>,
                                                             <<"guest">>,
                                                             test_util:uuid())).

no_permission_test(StartConnectionFun) ->
    ?assertMatch({error, access_refused},
                 StartConnectionFun(<<"test_user_no_perm">>,
                                    <<"test_user_no_perm">>,
                                    <<"/">>)).

connection_errors_test(Errors) ->
    Expected = [{error, access_refused},
                {error, access_refused},
                {error, auth_failure}],
    case Errors of
        Expected -> ok;
        Got      -> exit({wrong_result, Got})
    end.

channel_errors_test(Connection) ->
    ok = with_channel(fun test_exchange_redeclare/1, Connection),
    ok = with_channel(fun test_queue_redeclare/1, Connection),
    ok = with_channel(fun test_bad_exchange/1, Connection),
    test_util:wait_for_death(Connection).

%% Declare an exchange with a non-existent type.  Hard-error.
test_bad_exchange(Channel) ->
    ?assertMatch({error, #'connection.close'{}},
                 amqp_channel:call(Channel,
                                   #'exchange.declare'{exchange = <<"foo">>,
                                                       type = <<"driect">>})),
    test_util:wait_for_death(Channel).

%% Redeclare an exchange with the wrong type
test_exchange_redeclare(Channel) ->
    #'exchange.declare_ok'{} =
        amqp_channel:call(
          Channel, #'exchange.declare'{exchange= <<"bar">>,
                                       type = <<"topic">>}),
    ?assertMatch({error, #'channel.close'{}},
                 amqp_channel:call(Channel,
                                   #'exchange.declare'{exchange = <<"bar">>,
                                                       type = <<"direct">>})),
    test_util:wait_for_death(Channel).

%% Redeclare a queue with the wrong type
test_queue_redeclare(Channel) ->
    #'queue.declare_ok'{} =
        amqp_channel:call(
          Channel, #'queue.declare'{queue = <<"foo">>}),
    ?assertMatch({error, #'channel.close'{}},
                 amqp_channel:call(
                   Channel, #'queue.declare'{queue = <<"foo">>,
                                             durable = true})),
    test_util:wait_for_death(Channel).

with_channel(Fun, Connection) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    Fun(Channel).
