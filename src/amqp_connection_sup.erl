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

%% @private
-module(amqp_connection_sup).

-include("amqp_client.hrl").

-behaviour(supervisor2).

-export([start_link/2]).
-export([init/1]).

%%---------------------------------------------------------------------------
%% Interface
%%---------------------------------------------------------------------------

start_link(Module, AmqpParams) ->
    {ok, Sup} = supervisor2:start_link(?MODULE, []),
    SChMF = start_channels_manager_fun(Sup, AmqpParams),
    SIF = start_infrastructure_fun(Sup, AmqpParams),
    {ok, Connection} = supervisor2:start_child(
                         Sup,
                         {connection, {amqp_gen_connection, start_link,
                                       [Module, AmqpParams, SIF, SChMF, []]},
                          intrinsic, brutal_kill, worker,
                          [amqp_gen_connection]}),
    {ok, Sup, Connection}.

%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

start_infrastructure_fun(Sup, #amqp_params_network{}) ->
    fun (Sock, ChMgr) ->
            Connection = self(),
            {ok, CTSup, {MainReader, AState, Writer}} =
                supervisor2:start_child(
                  Sup,
                  {connection_type_sup, {amqp_connection_type_sup,
                                         start_link_network,
                                         [Sock, Connection, ChMgr]},
                   transient, infinity, supervisor,
                   [amqp_connection_type_sup]}),
            {ok, {MainReader, AState, Writer,
                  amqp_connection_type_sup:start_heartbeat_fun(CTSup)}}
    end;
start_infrastructure_fun(Sup, #amqp_params_direct{}) ->
    fun () ->
            {ok, _CTSup, Collector} =
                supervisor2:start_child(
                  Sup,
                  {connection_type_sup, {amqp_connection_type_sup,
                                         start_link_direct, []},
                   transient, infinity, supervisor,
                   [amqp_connection_type_sup]}),
            {ok, Collector}
    end.

start_channels_manager_fun(Sup, AmqpParams) ->
    fun () ->
            Connection = self(),
            {ok, ChSupSup} = supervisor2:start_child(
                       Sup,
                       {channel_sup_sup, {amqp_channel_sup_sup, start_link,
                                          [AmqpParams, Connection]},
                        intrinsic, infinity, supervisor,
                        [amqp_channel_sup_sup]}),
            {ok, _} = supervisor2:start_child(
                        Sup,
                        {channels_manager, {amqp_channels_manager, start_link,
                                            [Connection, ChSupSup]},
                         transient, ?MAX_WAIT, worker, [amqp_channels_manager]})
    end.

%%---------------------------------------------------------------------------
%% supervisor2 callbacks
%%---------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_all, 0, 1}, []}}.
