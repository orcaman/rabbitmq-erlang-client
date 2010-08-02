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

%% @private
-module(amqp_channel_util).

-include("amqp_client.hrl").

-export([open_channel/6]).
-export([channel_infrastructure_children/4,
         terminate_channel_infrastructure/2]).
-export([do/4]).
-export([new_channel_dict/0, is_channel_dict_empty/1, num_channels/1,
         register_channel/3, unregister_channel_number/2,
         unregister_channel_pid/2, resolve_channel_number/2,
         resolve_channel_pid/2, is_channel_number_registered/2,
         is_channel_pid_registered/2, channel_number/3]).
-export([broadcast_to_channels/2, handle_exit/4]).

%%---------------------------------------------------------------------------
%% Opening channels
%%---------------------------------------------------------------------------

%% Spawns a new channel supervision tree linked under the given connection
%% supervisor, starts monitoring the channel and registers it in the given
%% Channels dict
open_channel(Sup, ProposedNumber, MaxChannel, Driver, InfraArgs, Channels) ->
    ChannelNumber = channel_number(ProposedNumber, Channels, MaxChannel),
    ChannelSupSup = amqp_connection_sup:child(Sup, channel_sup_sup),
    {ok, ChannelSup} = amqp_channel_sup_sup:start_channel_sup(
                               ChannelSupSup, ChannelNumber, Driver, InfraArgs),
    ChannelPid = amqp_channel_sup:child(ChannelSup, channel),
    erlang:monitor(process, ChannelPid),
    NewChannels = register_channel(ChannelNumber, ChannelPid, Channels),
    {ChannelPid, NewChannels}.

channel_infrastructure_children(network, [Sock, _], GetChPid, ChNumber) ->
    [{framing, {rabbit_framing_channel, start_link, [GetChPid]},
      permanent, ?MAX_WAIT, worker, [rabbit_framing_channel]},
     {writer, {rabbit_writer, start_link, [Sock, ChNumber, ?FRAME_MIN_SIZE]},
      permanent, ?MAX_WAIT, worker, [rabbit_writer]}];
channel_infrastructure_children(direct, [User, VHost, Collector], GetChPid,
                                ChNumber) ->
    [{rabbit_channel,
      {rabbit_channel, start_link,
       [ChNumber, GetChPid, GetChPid, User, VHost, Collector]},
      permanent, ?MAX_WAIT, worker, [rabbit_channel]}].

terminate_channel_infrastructure(network, Sup) ->
    [Writer] = supervisor2:find_child(Sup, writer),
    rabbit_writer:flush(Writer),
    ok;
terminate_channel_infrastructure(direct, Sup) ->
    [RChannel] = supervisor2:find_child(Sup, rabbit_channel),
    rabbit_channel:shutdown(RChannel),
    ok.

%%---------------------------------------------------------------------------
%% Do
%%---------------------------------------------------------------------------

do(network, Sup, Method, Content) ->
    [Writer] = supervisor2:find_child(Sup, writer),
    case Content of
        none -> rabbit_writer:send_command_and_signal_back(Writer, Method,
                                                           self());
        _    -> rabbit_writer:send_command_and_signal_back(Writer, Method,
                                                           Content, self())
    end,
    receive
        rabbit_writer_send_command_signal -> ok
    end;
do(direct, Sup, Method, Content) ->
    [RChannel] = supervisor2:find_child(Sup, rabbit_channel),
    case Content of
        none -> rabbit_channel:do(RChannel, Method);
        _    -> rabbit_channel:do(RChannel, Method, Content)
    end.

%%---------------------------------------------------------------------------
%% Channel number/pid registration
%%---------------------------------------------------------------------------

%% New channel dictionary for keeping track of the mapping and reverse mapping
%% between the channel pid's and the channel numbers
new_channel_dict() ->
    {gb_trees:empty(), dict:new()}.

%% Returns true iff there are no channels currently registered in the given
%% dictionary
is_channel_dict_empty(_Channels = {TreeNP, _}) ->
    gb_trees:is_empty(TreeNP).

%% Returns the number of channels registered in the channels dictionary
num_channels(_Channels = {TreeNP, _}) ->
    gb_trees:size(TreeNP).

%% Register a channel in a given channel dictionary
register_channel(Number, Pid, _Channels = {TreeNP, DictPN}) ->
    case gb_trees:is_defined(Number, TreeNP) of
        false ->
            TreeNP1 = gb_trees:enter(Number, Pid, TreeNP),
            DictPN1 = dict:store(Pid, Number, DictPN),
            {TreeNP1, DictPN1};
        true ->
            erlang:error({channel_already_registered, Number})
    end.

%% Unregister a channel given its number
unregister_channel_number(Number, Channels = {TreeNP, _}) ->
    case gb_trees:lookup(Number, TreeNP) of
        {value, Pid} -> unregister_channel(Number, Pid, Channels);
        none         -> erlang:error(channel_number_not_registered)
    end.

%% Unregister a channel given its pid
unregister_channel_pid(Pid, Channels = {_, DictPN}) ->
    case dict:fetch(Pid, DictPN) of
        undefined -> erlang:error(channel_pid_not_registered);
        Number    -> unregister_channel(Number, Pid, Channels)
    end.

unregister_channel(Number, Pid, {TreeNP, DictPN}) ->
    TreeNP1 = gb_trees:delete(Number, TreeNP),
    DictPN1 = dict:erase(Pid, DictPN),
    {TreeNP1, DictPN1}.

%% Get channel pid, given its number. Returns undefined if channel number
%% is not registered.
resolve_channel_number(Number, _Channels = {TreeNP, _}) ->
    case gb_trees:lookup(Number, TreeNP) of
        {value, Pid} -> Pid;
        none         -> undefined
    end.

%% Get channel number, given its pid. Assumes pid is registered
resolve_channel_pid(Pid, _Channels = {_, DictPN}) ->
    dict:fetch(Pid, DictPN).

%% Returns true iff channel number is registered in the given channel
%% dictionary
is_channel_number_registered(Number, _Channels = {TreeNP, _}) ->
    gb_trees:is_defined(Number, TreeNP).

%% Returns true iff pid is registered in the given channel dictionary
is_channel_pid_registered(Pid, _Channels = {_, DictPN}) ->
    dict:is_key(Pid, DictPN).

%% Returns an available channel number in the given channel dictionary
channel_number(none, Channels, 0) ->
    channel_number(none, Channels, ?MAX_CHANNEL_NUMBER);
channel_number(none, _Channels = {TreeNP, _}, MaxChannel) ->
    case gb_trees:is_empty(TreeNP) of
        true ->
            1;
        false ->
            {Smallest, _} = gb_trees:smallest(TreeNP),
            if Smallest > 1 ->
                   Smallest - 1;
               true ->
                   {Largest, _} = gb_trees:largest(TreeNP),
                   if Largest < MaxChannel ->
                          Largest + 1;
                      true ->
                          find_available_number(gb_trees:iterator(TreeNP), 1)
                   end
            end
    end;
channel_number(ProposedNumber, Channels, 0) ->
    channel_number(ProposedNumber, Channels, ?MAX_CHANNEL_NUMBER);
channel_number(ProposedNumber, Channels, MaxChannel) ->
    IsNumberValid = ProposedNumber > 0 andalso
        ProposedNumber =< MaxChannel andalso
        not is_channel_number_registered(ProposedNumber, Channels),
    if IsNumberValid -> ProposedNumber;
       true          -> channel_number(none, Channels, MaxChannel)
    end.

find_available_number(It, Candidate) ->
    case gb_trees:next(It) of
        {Number, _, It1} ->
            if Number > Candidate   -> Number - 1;
               Number =:= Candidate -> find_available_number(It1, Candidate + 1);
               true                 -> erlang:error(unexpected_structure)
            end;
        none ->
            erlang:error(out_of_channel_numbers)
    end.

%%---------------------------------------------------------------------------
%% Other channel utilities
%%---------------------------------------------------------------------------

broadcast_to_channels(Message, _Channels = {_, DictPN}) ->
    dict:map(fun(ChannelPid, _) -> ChannelPid ! Message, ok end, DictPN),
    ok.

handle_exit(Pid, Reason, Channels, Closing) ->
    case is_channel_pid_registered(Pid, Channels) of
        true  -> handle_channel_exit(Pid, Reason, Closing);
        false -> ?LOG_WARN("Connection (~p) closing: received unexpected "
                           "down signal from (~p). Reason: ~p~n",
                           [self(), Pid, Reason]),
                 other
    end.

handle_channel_exit(_Pid, normal, _Closing) ->
    %% Normal amqp_channel shutdown
    normal;
handle_channel_exit(Pid, {server_initiated_close, Code, _Text}, false) ->
    %% Channel terminating (server sent 'channel.close')
    {IsHardError, _, _} = ?PROTOCOL:lookup_amqp_exception(
                            ?PROTOCOL:amqp_exception(Code)),
    case IsHardError of
        true  -> ?LOG_WARN("Connection (~p) closing: channel (~p) "
                           "received hard error from server~n", [self(), Pid]),
                 stop;
        false -> normal
    end;
handle_channel_exit(_Pid, {_CloseReason, _Code, _Text}, Closing)
  when Closing =/= false ->
    %% Channel terminating due to connection closing
    normal;
handle_channel_exit(Pid, Reason, _Closing) ->
    %% amqp_channel dies with internal reason - this takes
    %% the entire connection down
    ?LOG_WARN("Connection (~p) closing: channel (~p) died. Reason: ~p~n",
              [self(), Pid, Reason]),
    close.
