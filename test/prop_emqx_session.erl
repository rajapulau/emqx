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

-module(prop_emqx_session).

-include("emqx_mqtt.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(mock_modules,
        [ emqx_metrics
        , emqx_broker
        , emqx_misc
        , emqx_message
        , emqx_hooks
        , emqx_zone
        , emqx_pd
        ]).

-compile(export_all).
-compile(nowarn_export_all).

%%%%%%%%%%%%%%%%%%
%%% Properties %%%
%%%%%%%%%%%%%%%%%%
prop_session_pub(opts) -> [{numtests, 1000}].

prop_session_pub() ->
    emqx_logger:set_log_level(emergency),

    ?SETUP(fun() ->
                   ok = load(?mock_modules),
                   fun() -> ok = unload(?mock_modules) end
           end,
           ?FORALL({Session, OpList}, {session(), session_op_list()},
                   begin
                       try
                           apply_ops(Session, OpList),
                           true
                       after
                           ok
                       end
                   end)).

%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%

apply_ops(Session, []) ->
    ?assertEqual(session, element(1, Session));
apply_ops(Session, [Op | Rest]) ->
    NSession = apply_op(Session, Op),
    apply_ops(NSession, Rest).

apply_op(Session, info) ->
    Info = emqx_session:info(Session),
    ?assert(is_map(Info)),
    ?assertEqual(16, maps:size(Info)),
    Session;
apply_op(Session, attrs) ->
    Attrs = emqx_session:attrs(Session),
    ?assert(is_map(Attrs)),
    ?assertEqual(3, maps:size(Attrs)),
    Session;
apply_op(Session, stats) ->
    Stats = emqx_session:stats(Session),
    ?assert(is_list(Stats)),
    ?assertEqual(9, length(Stats)),
    Session;
apply_op(Session, {subscribe, {Client, TopicFilter, SubOpts}}) ->
    case emqx_session:subscribe(Client, TopicFilter, SubOpts, Session) of
        {ok, NSession} ->
            NSession;
        {error, ?RC_QUOTA_EXCEEDED} ->
            Session
    end;
apply_op(Session, {unsubscribe, {Client, TopicFilter}}) ->
    case emqx_session:unsubscribe(Client, TopicFilter, Session) of
        {ok, NSession} ->
            NSession;
        {error, ?RC_NO_SUBSCRIPTION_EXISTED} ->
            Session
    end;
apply_op(Session, {publish, {PacketId, Msg}}) ->
    case emqx_session:publish(PacketId, Msg, Session) of
        {ok, _Msg} ->
            Session;
        {ok, _Deliver, NSession} ->
            NSession;
        {error, _ErrorCode} ->
            Session
    end;
apply_op(Session, {puback, PacketId}) ->
    case emqx_session:puback(PacketId, Session) of
        {ok, _Msg} ->
            Session;
        {ok, _Deliver, NSession} ->
            NSession;
        {error, _ErrorCode} ->
            Session
    end;
apply_op(Session, {pubrec, PacketId}) ->
    case emqx_session:pubrec(PacketId, Session) of
        {ok, NSession} ->
            NSession;
        {error, _ErrorCode} ->
            Session
    end;
apply_op(Session, {pubrel, PacketId}) ->
    case emqx_session:pubrel(PacketId, Session) of
        {ok, NSession} ->
            NSession;
        {error, _ErrorCode} ->
            Session
    end;
apply_op(Session, {pubcomp, PacketId}) ->
    case emqx_session:pubcomp(PacketId, Session) of
        {ok, _Msgs} ->
            Session;
        {ok, _Msgs, NSession} ->
            NSession;
        {error, _ErrorCode} ->
            Session
    end;
apply_op(Session, {deliver, Delivers}) ->
    {ok, _Msgs, NSession} = emqx_session:deliver(Delivers, Session),
    NSession;
apply_op(Session, {timeout, {TRef, TimeoutMsg}}) ->
    case emqx_session:timeout(TRef, TimeoutMsg, Session) of
        {ok, NSession} ->
            NSession;
        {ok, _Msg, NSession} ->
            NSession
    end.

%%%%%%%%%%%%%%%%%%
%%% Generators %%%
%%%%%%%%%%%%%%%%%%
session_op_list() ->
    Union = [info,
             attrs,
             stats,
             {subscribe, sub_args()},
             {unsubscribe, unsub_args()},
             {publish, publish_args()},
             {puback, puback_args()},
             {pubrec, pubrec_args()},
             {pubrel, pubrel_args()},
             {pubcomp, pubcomp_args()},
             {deliver, deliver_args()},
             {timeout, timeout_args()}
            ],
    list(?LAZY(oneof(Union))).

deliver_args() ->
    list({deliver, topic(), message()}).

timeout_args() ->
    {tref(), timeout_msg()}.

sub_args() ->
    ?LET({ClientId, TopicFilter, SubOpts},
         {clientid(), topic(), sub_opts()},
         {#{client_id => ClientId}, TopicFilter, SubOpts}).

unsub_args() ->
    ?LET({ClientId, TopicFilter},
         {clientid(), topic()},
         {#{client_id => ClientId}, TopicFilter}).

publish_args() ->
    ?LET({PacketId, Message},
         {packetid(), message()},
         {PacketId, Message}).

puback_args() ->
    packetid().

pubrec_args() ->
    packetid().

pubrel_args() ->
    packetid().

pubcomp_args() ->
    packetid().

timeout_msg() ->
    oneof([retry_delivery, check_awaiting_rel]).

tref() -> oneof([tref, undefined]).

sub_opts() ->
    ?LET({RH, RAP, NL, QOS, SHARE, SUBID},
         {rh(), rap(), nl(), qos(), share(), subid()}
        , make_subopts(RH, RAP, NL, QOS, SHARE, SUBID)).

message() ->
    ?LET({QoS, Topic, Payload},
         {qos(), topic(), payload()},
         emqx_message:make(proper, QoS, Topic, Payload)).

subid() -> integer().

rh() -> oneof([0, 1, 2]).

rap() -> oneof([0, 1]).

nl() -> oneof([0, 1]).

qos() -> oneof([0, 1, 2]).

share() -> binary().

clientid() -> binary().

topic() -> ?LET(No, choose(1, 10), begin
                                       NoBin = integer_to_binary(No),
                                       <<"topic/", NoBin/binary>>
                                   end).

payload() -> binary().

packetid() -> choose(1, 30).

zone() ->
    ?LET(Zone, [{max_subscriptions, max_subscription()},
                {upgrade_qos, upgrade_qos()},
                {retry_interval, retry_interval()},
                {max_awaiting_rel, max_awaiting_rel()},
                {await_rel_timeout, await_rel_timeout()}]
        , maps:from_list(Zone)).

max_subscription() -> frequency([{33, 0},
                                 {33, 1},
                                 {34, choose(0,10)}]).

upgrade_qos() -> bool().

retry_interval() -> ?LET(Interval, choose(0, 20), Interval*1000).

max_awaiting_rel() -> choose(0, 10).

await_rel_timeout() -> ?LET(Interval, choose(0, 150), Interval*1000).

max_inflight() -> choose(0, 10).

expiry_interval() -> ?LET(EI, choose(1, 10), EI * 3600).

option() ->
    ?LET(Option, [{max_inflight, max_inflight()},
                  {expiry_interval, expiry_interval()}]
        , maps:from_list(Option)).

cleanstart() -> bool().

session() ->
    ?LET({CleanStart, Zone, Options},
         {cleanstart(), zone(), option()},
         begin
             Session = emqx_session:init(CleanStart, #{zone => Zone}, Options),
             emqx_session:set_pkt_id(Session, 16#ffff)
         end).

%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal functions %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%

make_subopts(RH, RAP, NL, QOS, SHARE, SubId) ->
    #{rh => RH,
      rap => RAP,
      nl => NL,
      qos => QOS,
      share => SHARE,
      subid => SubId}.


load(Modules) ->
    [mock(Module) || Module <- Modules],
    ok.

unload(Modules) ->
    lists:foreach(fun(Module) ->
                          ok = meck:unload(Module)
                  end, Modules),
    ok.

mock(Module) ->
    ok = meck:new(Module, [passthrough, no_history]),
    do_mock(Module, expect(Module)).

do_mock(emqx_metrics, Expect) ->
    Expect(inc, fun(_Anything) -> ok end);
do_mock(emqx_broker, Expect) ->
    Expect(subscribe, fun(_, _, _) -> ok end),
    Expect(set_subopts, fun(_, _) -> ok end),
    Expect(unsubscribe, fun(_) -> ok end),
    Expect(publish, fun(_) -> ok end);
do_mock(emqx_misc, Expect) ->
    Expect(start_timer, fun(_, _) -> tref end);
do_mock(emqx_message, Expect) ->
    Expect(set_header, fun(_Hdr, _Val, Msg) -> Msg end),
    Expect(is_expired, fun(_Msg) -> (rand:uniform(16) > 8) end);
do_mock(emqx_hooks, Expect) ->
    Expect(run, fun(_Hook, _Args) -> ok end);
do_mock(emqx_zone, Expect) ->
    Expect(get_env, fun(Env, Key, Default) -> maps:get(Key, Env, Default) end);
do_mock(emqx_pd, Expect) ->
    Expect(update_counter, fun(_stats, _num) -> ok end).

expect(Module) ->
    fun(OldFun, NewFun) ->
            ok = meck:expect(Module, OldFun, NewFun)
    end.
