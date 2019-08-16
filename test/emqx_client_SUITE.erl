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

-module(emqx_client_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-import(lists, [nth/2]).

-include("emqx_mqtt.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(TOPICS, [<<"TopicA">>,
                 <<"TopicA/B">>,
                 <<"Topic/C">>,
                 <<"TopicA/C">>,
                 <<"/TopicA">>
                ]).

-define(WILD_TOPICS, [<<"TopicA/+">>,
                      <<"+/C">>,
                      <<"#">>,
                      <<"/#">>,
                      <<"/+">>,
                      <<"+/+">>,
                      <<"TopicA/#">>
                     ]).


all() ->
    [{group, mqttv3},
     {group, mqttv4},
     {group, mqttv5}
    ].

groups() ->
    [{mqttv3, [non_parallel_tests],
      [t_basic_v3
      ]},
     {mqttv4, [non_parallel_tests],
      [t_basic_v4,
       %% t_will_message,
       %% t_offline_message_queueing,
       t_overlapping_subscriptions,
       %% t_keepalive,
       %% t_redelivery_on_reconnect,
       %% subscribe_failure_test,
       t_dollar_topics
      ]},
     {mqttv5, [non_parallel_tests],
      [t_basic_with_props_v5
      ]}
    ].

init_per_suite(Config) ->
    emqx_ct_helpers:start_apps([]),
    Config.

end_per_suite(_Config) ->
    emqx_ct_helpers:stop_apps([]).

%%--------------------------------------------------------------------
%% Test cases for MQTT v3
%%--------------------------------------------------------------------

t_basic_v3(_) ->
    t_basic([{proto_ver, v3}]).

%%--------------------------------------------------------------------
%% Test cases for MQTT v4
%%--------------------------------------------------------------------

t_basic_v4(_Config) ->
    t_basic([{proto_ver, v4}]).

t_will_message(_Config) ->
    {ok, C1} = emqx_client:start_link([{clean_start, true},
                                       {will_topic, nth(3, ?TOPICS)},
                                       {will_payload, <<"client disconnected">>},
                                       {keepalive, 1}]),
    {ok, _} = emqx_client:connect(C1),

    {ok, C2} = emqx_client:start_link(),
    {ok, _} = emqx_client:connect(C2),

    {ok, _, [2]} = emqx_client:subscribe(C2, nth(3, ?TOPICS), 2),
    timer:sleep(5),
    ok = emqx_client:stop(C1),
    timer:sleep(5),
    ?assertEqual(1, length(recv_msgs(1))),
    ok = emqx_client:disconnect(C2),
    ct:pal("Will message test succeeded").

t_offline_message_queueing(_) ->
    {ok, C1} = emqx_client:start_link([{clean_start, false},
                                       {client_id, <<"c1">>}]),
    {ok, _} = emqx_client:connect(C1),

    {ok, _, [2]} = emqx_client:subscribe(C1, nth(6, ?WILD_TOPICS), 2),
    ok = emqx_client:disconnect(C1),
    {ok, C2} = emqx_client:start_link([{clean_start, true},
                                       {client_id, <<"c2">>}]),
    {ok, _} = emqx_client:connect(C2),

    ok = emqx_client:publish(C2, nth(2, ?TOPICS), <<"qos 0">>, 0),
    {ok, _} = emqx_client:publish(C2, nth(3, ?TOPICS), <<"qos 1">>, 1),
    {ok, _} = emqx_client:publish(C2, nth(4, ?TOPICS), <<"qos 2">>, 2),
    timer:sleep(10),
    emqx_client:disconnect(C2),
    {ok, C3} = emqx_client:start_link([{clean_start, false},
                                       {client_id, <<"c1">>}]),
    {ok, _} = emqx_client:connect(C3),

    timer:sleep(10),
    emqx_client:disconnect(C3),
    ?assertEqual(3, length(recv_msgs(3))).

t_overlapping_subscriptions(_) ->
    {ok, C} = emqx_client:start_link([]),
    {ok, _} = emqx_client:connect(C),

    {ok, _, [2, 1]} = emqx_client:subscribe(C, [{nth(7, ?WILD_TOPICS), 2},
                                                {nth(1, ?WILD_TOPICS), 1}]),
    timer:sleep(10),
    {ok, _} = emqx_client:publish(C, nth(4, ?TOPICS), <<"overlapping topic filters">>, 2),
    timer:sleep(10),

    Num = length(recv_msgs(2)),
    ?assert(lists:member(Num, [1, 2])),
    if
        Num == 1 ->
            ct:pal("This server is publishing one message for all
                   matching overlapping subscriptions, not one for each.");
        Num == 2 ->
            ct:pal("This server is publishing one message per each
                    matching overlapping subscription.");
        true -> ok
    end,
    emqx_client:disconnect(C).

%% t_keepalive_test(_) ->
%%     ct:print("Keepalive test starting"),
%%     {ok, C1, _} = emqx_client:start_link([{clean_start, true},
%%                                           {keepalive, 5},
%%                                           {will_flag, true},
%%                                           {will_topic, nth(5, ?TOPICS)},
%%                                           %% {will_qos, 2},
%%                                           {will_payload, <<"keepalive expiry">>}]),
%%     ok = emqx_client:pause(C1),
%%     {ok, C2, _} = emqx_client:start_link([{clean_start, true},
%%                                           {keepalive, 0}]),
%%     {ok, _, [2]} = emqx_client:subscribe(C2, nth(5, ?TOPICS), 2),
%%     ok = emqx_client:disconnect(C2),
%%     ?assertEqual(1, length(recv_msgs(1))),
%%     ct:print("Keepalive test succeeded").

t_redelivery_on_reconnect(_) ->
    ct:pal("Redelivery on reconnect test starting"),
    {ok, C1} = emqx_client:start_link([{clean_start, false},
                                       {client_id, <<"c">>}]),
    {ok, _} = emqx_client:connect(C1),

    {ok, _, [2]} = emqx_client:subscribe(C1, nth(7, ?WILD_TOPICS), 2),
    timer:sleep(10),
    ok = emqx_client:pause(C1),
    {ok, _} = emqx_client:publish(C1, nth(2, ?TOPICS), <<>>,
                                  [{qos, 1}, {retain, false}]),
    {ok, _} = emqx_client:publish(C1, nth(4, ?TOPICS), <<>>,
                                  [{qos, 2}, {retain, false}]),
    timer:sleep(10),
    ok = emqx_client:disconnect(C1),
    ?assertEqual(0, length(recv_msgs(2))),
    {ok, C2} = emqx_client:start_link([{clean_start, false},
                                       {client_id, <<"c">>}]),
    {ok, _} = emqx_client:connect(C2),

    timer:sleep(10),
    ok = emqx_client:disconnect(C2),
    ?assertEqual(2, length(recv_msgs(2))).

%% t_subscribe_sys_topics(_) ->
%%     ct:print("Subscribe failure test starting"),
%%     {ok, C, _} = emqx_client:start_link([]),
%%     {ok, _, [2]} = emqx_client:subscribe(C, <<"$SYS/#">>, 2),
%%     timer:sleep(10),
%%     ct:print("Subscribe failure test succeeded").

t_dollar_topics(_) ->
    ct:pal("$ topics test starting"),
    {ok, C} = emqx_client:start_link([{clean_start, true},
                                      {keepalive, 0}]),
    {ok, _} = emqx_client:connect(C),

    {ok, _, [1]} = emqx_client:subscribe(C, nth(6, ?WILD_TOPICS), 1),
    {ok, _} = emqx_client:publish(C, << <<"$">>/binary, (nth(2, ?TOPICS))/binary>>,
                                  <<"test">>, [{qos, 1}, {retain, false}]),
    timer:sleep(10),
    ?assertEqual(0, length(recv_msgs(1))),
    ok = emqx_client:disconnect(C),
    ct:pal("$ topics test succeeded").

%%--------------------------------------------------------------------
%% Test cases for MQTT v5
%%--------------------------------------------------------------------

t_basic_with_props_v5(_) ->
    t_basic([{proto_ver, v5},
             {properties, #{'Receive-Maximum' => 4}}
            ]).

%%--------------------------------------------------------------------
%% General test cases.
%%--------------------------------------------------------------------

t_basic(Opts) ->
    Topic = nth(1, ?TOPICS),
    {ok, C} = emqx_client:start_link([{proto_ver, v4}]),
    {ok, _} = emqx_client:connect(C),
    {ok, _, [1]} = emqx_client:subscribe(C, Topic, qos1),
    {ok, _, [2]} = emqx_client:subscribe(C, Topic, qos2),
    {ok, _} = emqx_client:publish(C, Topic, <<"qos 2">>, 2),
    {ok, _} = emqx_client:publish(C, Topic, <<"qos 2">>, 2),
    {ok, _} = emqx_client:publish(C, Topic, <<"qos 2">>, 2),
    ?assertEqual(3, length(recv_msgs(3))),
    ok = emqx_client:disconnect(C).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

recv_msgs(Count) ->
    recv_msgs(Count, []).

recv_msgs(0, Msgs) ->
    Msgs;
recv_msgs(Count, Msgs) ->
    receive
        {publish, Msg} ->
            recv_msgs(Count-1, [Msg|Msgs]);
        _Other -> recv_msgs(Count, Msgs) %%TODO:: remove the branch?
    after 100 ->
        Msgs
    end.
