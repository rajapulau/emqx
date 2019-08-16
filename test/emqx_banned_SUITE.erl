%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_banned_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("emqx.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> emqx_ct:all(?MODULE).

init_per_suite(Config) ->
    application:load(emqx),
    ok = ekka:start(),
    Config.

end_per_suite(_Config) ->
    ekka:stop(),
    ekka_mnesia:ensure_stopped(),
    ekka_mnesia:delete_schema().

t_add_delete(_) ->
    Banned = #banned{who = {client_id, <<"TestClient">>},
                     reason = <<"test">>,
                     by = <<"banned suite">>,
                     desc = <<"test">>,
                     until = erlang:system_time(second) + 1000
                    },
    ok = emqx_banned:add(Banned),
    ?assertEqual(1, emqx_banned:info(size)),
    ok = emqx_banned:delete({client_id, <<"TestClient">>}),
    ?assertEqual(0, emqx_banned:info(size)).

t_check(_) ->
    ok = emqx_banned:add(#banned{who = {client_id, <<"BannedClient">>}}),
    ok = emqx_banned:add(#banned{who = {username, <<"BannedUser">>}}),
    ok = emqx_banned:add(#banned{who = {ipaddr, {192,168,0,1}}}),
    ?assertEqual(3, emqx_banned:info(size)),
    Client1 = #{client_id => <<"BannedClient">>,
                username => <<"user">>,
                peername => {{127,0,0,1}, 5000}
               },
    Client2 = #{client_id => <<"client">>,
                username => <<"BannedUser">>,
                peername => {{127,0,0,1}, 5000}
               },
    Client3 = #{client_id => <<"client">>,
                username => <<"user">>,
                peername => {{192,168,0,1}, 5000}
               },
    Client4 = #{client_id => <<"client">>,
                username => <<"user">>,
                peername => {{127,0,0,1}, 5000}
               },
    ?assert(emqx_banned:check(Client1)),
    ?assert(emqx_banned:check(Client2)),
    ?assert(emqx_banned:check(Client3)),
    ?assertNot(emqx_banned:check(Client4)),
    ok = emqx_banned:delete({client_id, <<"BannedClient">>}),
    ok = emqx_banned:delete({username, <<"BannedUser">>}),
    ok = emqx_banned:delete({ipaddr, {192,168,0,1}}),
    ?assertNot(emqx_banned:check(Client1)),
    ?assertNot(emqx_banned:check(Client2)),
    ?assertNot(emqx_banned:check(Client3)),
    ?assertNot(emqx_banned:check(Client4)),
    ?assertEqual(0, emqx_banned:info(size)).

