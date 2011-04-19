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

-include("amqp_client.hrl").

-type(state() :: any()).
-type(consume() :: #'basic.consume'{}).
-type(consume_ok() :: #'basic.consume_ok'{}).
-type(cancel() :: #'basic.cancel'{}).
-type(cancel_ok() :: #'basic.cancel_ok'{}).
-type(deliver() :: {#'basic.deliver'{}, #amqp_msg{}}).

-spec(init/1 :: (Args :: [any()]) -> state()).
-spec(handle_consume_ok/3 :: (ConsumeOk :: consume_ok(), Consume :: consume(),
                              State :: state()) -> NewState :: state()).
-spec(handle_cancel_ok/3 :: (CancelOk :: cancel_ok(), Cancel :: cancel(),
                             State :: state()) -> NewState :: state()).
-spec(handle_cancel/2 :: (Cancel :: cancel(), State :: state()) ->
                             NewState :: state()).
-spec(handle_deliver/2 :: (Deliver :: deliver(), State :: state()) ->
                              NewState :: state()).
-spec(handle_call/2 :: (Call :: any(), State :: state()) ->
                           {Reply :: any(), NewState :: state()}).
-spec(terminate/2 :: (Reason :: any(), State :: state()) ->
                         NewState :: state()).
