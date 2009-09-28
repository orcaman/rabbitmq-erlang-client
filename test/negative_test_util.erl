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
-module(negative_test_util).

-include("amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

non_existent_exchange_test(Connection) ->
    X = test_util:uuid(),
    RoutingKey = <<"a">>, 
    Payload = <<"foobar">>,
    Channel = amqp_connection:open_channel(Connection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = X}),
    %% Deliberately mix up the routingkey and exchange arguments
    Publish = #'basic.publish'{exchange = RoutingKey, routing_key = X},
    amqp_channel:call(Channel, Publish, #amqp_msg{payload = Payload}),
    test_util:wait_for_death(Channel),
    ?assertMatch(true, is_process_alive(Connection)),
    amqp_connection:close(Connection).

bogus_rpc_test(Connection) ->
    X = test_util:uuid(),
    Q = test_util:uuid(),
    R = test_util:uuid(),
    Channel = amqp_connection:open_channel(Connection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = X}),
    %% Deliberately bind to a non-existent queue
    Bind = #'queue.bind'{exchange = X, queue = Q, routing_key = R},
    try amqp_channel:call(Channel, Bind) of
        _ -> exit(expected_to_exit)
    catch
        exit:{{server_initiated_close, Code, _},_} ->
            ?assertMatch(?NOT_FOUND, Code)
    end,
    test_util:wait_for_death(Channel),
    ?assertMatch(true, is_process_alive(Connection)),
    amqp_connection:close(Connection).

hard_error_test(Connection) ->
    Channel = amqp_connection:open_channel(Connection),
    Qos = #'basic.qos'{global = true},
    try amqp_channel:call(Channel, Qos) of
        _ -> exit(expected_to_exit)
    catch
        exit:{{server_initiated_close, Code, _Text}, _} ->
            ?assertMatch(?NOT_IMPLEMENTED, Code)
    end,
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection).


%% Refer to bug 21172 to find out how this is caused
channel_death_test(Connection) ->
    C1 = amqp_connection:open_channel(Connection),
    ok = amqp_channel:close(C1),
    C2 = amqp_connection:open_channel(Connection),
    Publish = #'basic.publish'{routing_key = <<>>, exchange = <<>>},
    Message = #amqp_msg{props = <<>>, payload = <<>>},
    ok = amqp_channel:call(C2, Publish, Message),
    timer:sleep(1000),
    ?assertNot(is_process_alive(C2)),
    ?assert(is_process_alive(Connection)),
    C3 = amqp_connection:open_channel(Connection),
    ?assert(is_process_alive(C3)),
    test_util:teardown(Connection, C3).
    

non_existent_user_test() ->
    Params = #amqp_params{username = test_util:uuid(),
                          password = test_util:uuid()},
    ?assertError(_, amqp_connection:start_network(Params)).

invalid_password_test() ->
    Params = #amqp_params{username = <<"guest">>,
                          password = test_util:uuid()},
    ?assertError(_, amqp_connection:start_network(Params)).

non_existent_vhost_test() ->
    Params = #amqp_params{virtual_host = test_util:uuid()},
    ?assertError(_, amqp_connection:start_network(Params)).

no_permission_test() ->
    Params = #amqp_params{username = <<"test_user_no_perm">>,
                          password = <<"test_user_no_perm">>},
    ?assertError(_, amqp_connection:start_network(Params)).
