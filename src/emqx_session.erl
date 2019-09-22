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

%%--------------------------------------------------------------------
%% @doc
%% A stateful interaction between a Client and a Server. Some Sessions
%% last only as long as the Network Connection, others can span multiple
%% consecutive Network Connections between a Client and a Server.
%%
%% The Session State in the Server consists of:
%%
%% The existence of a Session, even if the rest of the Session State is empty.
%%
%% The Clients subscriptions, including any Subscription Identifiers.
%%
%% QoS 1 and QoS 2 messages which have been sent to the Client, but have not
%% been completely acknowledged.
%%
%% QoS 1 and QoS 2 messages pending transmission to the Client and OPTIONALLY
%% QoS 0 messages pending transmission to the Client.
%%
%% QoS 2 messages which have been received from the Client, but have not been
%% completely acknowledged.The Will Message and the Will Delay Interval
%%
%% If the Session is currently not connected, the time at which the Session
%% will end and Session State will be discarded.
%% @end
%%--------------------------------------------------------------------

%% MQTT Session
-module(emqx_session).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").
-include("logger.hrl").
-include("types.hrl").

-logger_header("[Session]").

-export([init/2]).

-export([ info/1
        , info/2
        , attrs/1
        , stats/1
        ]).

%% Exports for unit tests
-export([set_field/3]).

-export([update_expiry_interval/2]).

-export([ subscribe/4
        , unsubscribe/3
        ]).

-export([ publish/3
        , puback/2
        , pubrec/2
        , pubrel/2
        , pubcomp/2
        ]).

-export([ deliver/2
        , enqueue/2
        , retry/1
        ]).

-export([ takeover/1
        , resume/2
        , redeliver/1
        ]).

-export([expire/2]).

-export_type([session/0]).

-import(emqx_zone, [get_env/3]).

-record(session, {
          %% Client’s Subscriptions.
          subscriptions :: map(),
          %% Max subscriptions allowed
          max_subscriptions :: non_neg_integer(),
          %% Upgrade QoS?
          upgrade_qos :: boolean(),
          %% Client <- Broker:
          %% Inflight QoS1, QoS2 messages sent to the client but unacked.
          inflight :: emqx_inflight:inflight(),
          %% All QoS1, QoS2 messages published to when client is disconnected.
          %% QoS 1 and QoS 2 messages pending transmission to the Client.
          %%
          %% Optionally, QoS 0 messages pending transmission to the Client.
          mqueue :: emqx_mqueue:mqueue(),
          %% Next packet id of the session
          next_pkt_id = 1 :: emqx_types:packet_id(),
          %% Retry interval for redelivering QoS1/2 messages
          retry_interval :: timeout(),
          %% Client -> Broker:
          %% Inflight QoS2 messages received from client and waiting for pubrel.
          awaiting_rel :: map(),
          %% Max Packets Awaiting PUBREL
          max_awaiting_rel :: non_neg_integer(),
          %% Awaiting PUBREL Timeout
          await_rel_timeout :: timeout(),
          %% Session Expiry Interval
          expiry_interval :: timeout(),
          %% Enqueue Count
          enqueue_cnt :: non_neg_integer(),
          %% Created at
          created_at :: erlang:timestamp()

         }).

-opaque(session() :: #session{}).

-type(publish() :: {publish, emqx_types:packet_id(), emqx_types:message()}).

-define(DEFAULT_BATCH_N, 1000).
-define(ATTR_KEYS, [expiry_interval, created_at]).
-define(INFO_KEYS, [subscriptions, max_subscriptions, upgrade_qos, inflight,
                    max_inflight, retry_interval, mqueue_len, max_mqueue,
                    mqueue_dropped, next_pkt_id, awaiting_rel, max_awaiting_rel,
                    await_rel_timeout, expiry_interval, created_at]).
-define(STATS_KEYS, [subscriptions_cnt, max_subscriptions, inflight, max_inflight,
                     mqueue_len, max_mqueue, mqueue_dropped, awaiting_rel,
                     max_awaiting_rel, enqueue_cnt]).

%%--------------------------------------------------------------------
%% Init a session
%%--------------------------------------------------------------------

%% @doc Init a session.
-spec(init(emqx_types:client(), Options :: map()) -> session()).
init(#{zone := Zone}, #{max_inflight    := MaxInflight,
                        expiry_interval := ExpiryInterval}) ->
    #session{max_subscriptions = get_env(Zone, max_subscriptions, 0),
             subscriptions     = #{},
             upgrade_qos       = get_env(Zone, upgrade_qos, false),
             inflight          = emqx_inflight:new(MaxInflight),
             mqueue            = init_mqueue(Zone),
             next_pkt_id       = 1,
             retry_interval    = get_env(Zone, retry_interval, 0),
             awaiting_rel      = #{},
             max_awaiting_rel  = get_env(Zone, max_awaiting_rel, 100),
             await_rel_timeout = get_env(Zone, await_rel_timeout, 3600*1000),
             expiry_interval   = ExpiryInterval,
             enqueue_cnt       = 0,
             created_at        = os:timestamp()
            }.

init_mqueue(Zone) ->
    emqx_mqueue:init(#{max_len => get_env(Zone, max_mqueue_len, 1000),
                       store_qos0 => get_env(Zone, mqueue_store_qos0, true),
                       priorities => get_env(Zone, mqueue_priorities, none),
                       default_priority => get_env(Zone, mqueue_default_priority, lowest)
                      }).

%% @doc Get infos of the session.
-spec(info(session()) -> emqx_types:infos()).
info(Session) ->
    maps:from_list(info(?INFO_KEYS, Session)).

%% Get attrs of the session.
-spec(attrs(session()) -> emqx_types:attrs()).
attrs(Session) ->
    maps:from_list(info(?ATTR_KEYS, Session)).

%% @doc Get stats of the session.
-spec(stats(session()) -> emqx_types:stats()).
stats(Session) -> info(?STATS_KEYS, Session).

info(Keys, Session) when is_list(Keys) ->
    [{Key, info(Key, Session)} || Key <- Keys];
info(subscriptions, #session{subscriptions = Subs}) ->
    Subs;
info(subscriptions_cnt, #session{subscriptions = Subs}) ->
    maps:size(Subs);
info(max_subscriptions, #session{max_subscriptions = MaxSubs}) ->
    MaxSubs;
info(upgrade_qos, #session{upgrade_qos = UpgradeQoS}) ->
    UpgradeQoS;
info(inflight, #session{inflight = Inflight}) ->
    emqx_inflight:size(Inflight);
info(max_inflight, #session{inflight = Inflight}) ->
    emqx_inflight:max_size(Inflight);
info(retry_interval, #session{retry_interval = Interval}) ->
    Interval;
info(mqueue_len, #session{mqueue = MQueue}) ->
    emqx_mqueue:len(MQueue);
info(max_mqueue, #session{mqueue = MQueue}) ->
    emqx_mqueue:max_len(MQueue);
info(mqueue_dropped, #session{mqueue = MQueue}) ->
    emqx_mqueue:dropped(MQueue);
info(next_pkt_id, #session{next_pkt_id = PacketId}) ->
    PacketId;
info(awaiting_rel, #session{awaiting_rel = AwaitingRel}) ->
    maps:size(AwaitingRel);
info(max_awaiting_rel, #session{max_awaiting_rel = MaxAwaitingRel}) ->
    MaxAwaitingRel;
info(await_rel_timeout, #session{await_rel_timeout = Timeout}) ->
    Timeout;
info(expiry_interval, #session{expiry_interval = Interval}) ->
    Interval;
info(enqueue_cnt, #session{enqueue_cnt = Cnt}) ->
    Cnt;
info(created_at, #session{created_at = CreatedAt}) ->
    CreatedAt.

%% For tests
set_field(Name, Val, Channel) ->
    Fields = record_info(fields, session),
    Pos = emqx_misc:index_of(Name, Fields),
    setelement(Pos+1, Channel, Val).

update_expiry_interval(ExpiryInterval, Session) ->
    Session#session{expiry_interval = ExpiryInterval}.

-spec(takeover(session()) -> ok).
takeover(#session{subscriptions = Subs}) ->
    lists:foreach(fun({TopicFilter, _SubOpts}) ->
                          ok = emqx_broker:unsubscribe(TopicFilter)
                  end, maps:to_list(Subs)).

-spec(resume(emqx_types:client_id(), session()) -> ok).
resume(ClientId, #session{subscriptions = Subs}) ->
    %% 1. Subscribe again.
    lists:foreach(fun({TopicFilter, SubOpts}) ->
                          ok = emqx_broker:subscribe(TopicFilter, ClientId, SubOpts)
                  end, maps:to_list(Subs)).
    %% 2. Run hooks.
    %% ok = emqx_hooks:run('session.resumed', [#{client_id => ClientId}, attrs(Session)]),
    %% TODO: 3. Redeliver: Replay delivery and Dequeue pending messages
    %%Session.

redeliver(Session = #session{inflight = Inflight}) ->
    Publishes = lists:map(fun({PacketId, {pubrel, _Ts}}) ->
                                  {pubrel, PacketId, ?RC_SUCCESS};
                             ({PacketId, {Msg, _Ts}}) ->
                                  {publish, PacketId, Msg}
                          end, emqx_inflight:to_list(Inflight)),
    case dequeue(Session) of
        {ok, NSession} ->
            {ok, Publishes, NSession};
        {ok, More, NSession} ->
            {ok, lists:append(Publishes, More), NSession}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: SUBSCRIBE
%%--------------------------------------------------------------------

-spec(subscribe(emqx_types:client(), emqx_types:topic(), emqx_types:subopts(), session())
      -> {ok, session()} | {error, emqx_types:reason_code()}).
subscribe(Client, TopicFilter, SubOpts, Session = #session{subscriptions = Subs}) ->
    case is_subscriptions_full(Session)
        andalso (not maps:is_key(TopicFilter, Subs)) of
        true  -> {error, ?RC_QUOTA_EXCEEDED};
        false ->
            do_subscribe(Client, TopicFilter, SubOpts, Session)
    end.

is_subscriptions_full(#session{max_subscriptions = 0}) ->
    false;
is_subscriptions_full(#session{max_subscriptions = MaxLimit,
                               subscriptions = Subs}) ->
    maps:size(Subs) >= MaxLimit.

-compile({inline, [do_subscribe/4]}).
do_subscribe(Client = #{client_id := ClientId}, TopicFilter, SubOpts,
             Session = #session{subscriptions = Subs}) ->
    case IsNew = (not maps:is_key(TopicFilter, Subs)) of
        true ->
            ok = emqx_broker:subscribe(TopicFilter, ClientId, SubOpts);
        false ->
            _ = emqx_broker:set_subopts(TopicFilter, SubOpts)
    end,
    ok = emqx_hooks:run('session.subscribed',
                        [Client, TopicFilter, SubOpts#{is_new => IsNew}]),
    {ok, Session#session{subscriptions = maps:put(TopicFilter, SubOpts, Subs)}}.

%%--------------------------------------------------------------------
%% Client -> Broker: UNSUBSCRIBE
%%--------------------------------------------------------------------

-spec(unsubscribe(emqx_types:client(), emqx_types:topic(), session())
      -> {ok, session()} | {error, emqx_types:reason_code()}).
unsubscribe(Client, TopicFilter, Session = #session{subscriptions = Subs}) ->
    case maps:find(TopicFilter, Subs) of
        {ok, SubOpts} ->
            ok = emqx_broker:unsubscribe(TopicFilter),
            ok = emqx_hooks:run('session.unsubscribed', [Client, TopicFilter, SubOpts]),
            {ok, Session#session{subscriptions = maps:remove(TopicFilter, Subs)}};
        error ->
            {error, ?RC_NO_SUBSCRIPTION_EXISTED}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBLISH
%%--------------------------------------------------------------------

-spec(publish(emqx_types:packet_id(), emqx_types:message(), session())
      -> {ok, emqx_types:publish_result()} |
         {ok, emqx_types:publish_result(), session()} |
         {error, emqx_types:reason_code()}).
publish(PacketId, Msg = #message{qos = ?QOS_2}, Session) ->
    case is_awaiting_full(Session) of
        false ->
            do_publish(PacketId, Msg, Session);
        true ->
            {error, ?RC_RECEIVE_MAXIMUM_EXCEEDED}
    end;

%% Publish QoS0/1 directly
publish(_PacketId, Msg, _Session) ->
    {ok, emqx_broker:publish(Msg)}.

is_awaiting_full(#session{max_awaiting_rel = 0}) ->
    false;
is_awaiting_full(#session{awaiting_rel = AwaitingRel,
                          max_awaiting_rel = MaxLimit}) ->
    maps:size(AwaitingRel) >= MaxLimit.

-compile({inline, [do_publish/3]}).
do_publish(PacketId, Msg = #message{timestamp = Ts},
           Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:is_key(PacketId, AwaitingRel) of
        false ->
            DeliverResults = emqx_broker:publish(Msg),
            AwaitingRel1 = maps:put(PacketId, Ts, AwaitingRel),
            Session1 = Session#session{awaiting_rel = AwaitingRel1},
            {ok, DeliverResults, Session1};
        true ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBACK
%%--------------------------------------------------------------------

-spec(puback(emqx_types:packet_id(), session())
      -> {ok, emqx_types:message(), session()}
       | {ok, emqx_types:message(), list(publish()), session()}
       | {error, emqx_types:reason_code()}).
puback(PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, {Msg, _Ts}} when is_record(Msg, message) ->
            Inflight1 = emqx_inflight:delete(PacketId, Inflight),
            return_with(Msg, dequeue(Session#session{inflight = Inflight1}));
        {value, {_Pubrel, _Ts}} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

return_with(Msg, {ok, Session}) ->
    {ok, Msg, Session};
return_with(Msg, {ok, Publishes, Session}) ->
    {ok, Msg, Publishes, Session}.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREC
%%--------------------------------------------------------------------

-spec(pubrec(emqx_types:packet_id(), session())
      -> {ok, emqx_types:message(), session()} | {error, emqx_types:reason_code()}).
pubrec(PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:lookup(PacketId, Inflight) of
        {value, {Msg, _Ts}} when is_record(Msg, message) ->
            Inflight1 = emqx_inflight:update(PacketId, {pubrel, os:timestamp()}, Inflight),
            {ok, Msg, Session#session{inflight = Inflight1}};
        {value, {pubrel, _Ts}} ->
            {error, ?RC_PACKET_IDENTIFIER_IN_USE};
        none ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBREL
%%--------------------------------------------------------------------

-spec(pubrel(emqx_types:packet_id(), session())
      -> {ok, session()} | {error, emqx_types:reason_code()}).
pubrel(PacketId, Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:take(PacketId, AwaitingRel) of
        {_Ts, AwaitingRel1} ->
            {ok, Session#session{awaiting_rel = AwaitingRel1}};
        error ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
      end.

%%--------------------------------------------------------------------
%% Client -> Broker: PUBCOMP
%%--------------------------------------------------------------------

-spec(pubcomp(emqx_types:packet_id(), session())
      -> {ok, session()} | {ok, list(publish()), session()}
       | {error, emqx_types:reason_code()}).
pubcomp(PacketId, Session = #session{inflight = Inflight}) ->
    case emqx_inflight:contain(PacketId, Inflight) of
        true ->
            Inflight1 = emqx_inflight:delete(PacketId, Inflight),
            dequeue(Session#session{inflight = Inflight1});
        false ->
            {error, ?RC_PACKET_IDENTIFIER_NOT_FOUND}
    end.

%%--------------------------------------------------------------------
%% Dequeue Msgs
%%--------------------------------------------------------------------

dequeue(Session = #session{inflight = Inflight, mqueue = Q}) ->
    case emqx_mqueue:is_empty(Q) of
        true  -> {ok, Session};
        false ->
            {Msgs, Q1} = dequeue(batch_n(Inflight), [], Q),
            deliver(lists:reverse(Msgs), [], Session#session{mqueue = Q1})
    end.

dequeue(Cnt, Msgs, Q) when Cnt =< 0 ->
    {Msgs, Q};

dequeue(Cnt, Msgs, Q) ->
    case emqx_mqueue:out(Q) of
        {empty, _Q} -> {Msgs, Q};
        {{value, Msg}, Q1} ->
            dequeue(Cnt-1, [Msg|Msgs], Q1)
    end.

batch_n(Inflight) ->
    case emqx_inflight:max_size(Inflight) of
        0 -> ?DEFAULT_BATCH_N;
        Sz -> Sz - emqx_inflight:size(Inflight)
    end.

%%--------------------------------------------------------------------
%% Broker -> Client: Publish | Msg
%%--------------------------------------------------------------------

deliver(Delivers, Session = #session{subscriptions = Subs})
  when is_list(Delivers) ->
    Msgs = [enrich_subopt(get_subopts(Topic, Subs), Msg, Session)
            || {deliver, Topic, Msg} <- Delivers],
    deliver(Msgs, [], Session).

deliver([], Publishes, Session) ->
    {ok, lists:reverse(Publishes), Session};

deliver([Msg = #message{qos = ?QOS_0}|More], Acc, Session) ->
    deliver(More, [{publish, undefined, Msg}|Acc], Session);

deliver([Msg = #message{qos = QoS}|More], Acc,
        Session = #session{next_pkt_id = PacketId, inflight = Inflight})
    when QoS =:= ?QOS_1 orelse QoS =:= ?QOS_2 ->
    case emqx_inflight:is_full(Inflight) of
        true ->
            deliver(More, Acc, enqueue(Msg, Session));
        false ->
            Publish = {publish, PacketId, Msg},
            Session1 = await(PacketId, Msg, Session),
            deliver(More, [Publish|Acc], next_pkt_id(Session1))
    end.

enqueue(Delivers, Session = #session{subscriptions = Subs}) when is_list(Delivers) ->
    Msgs = [enrich_subopt(get_subopts(Topic, Subs), Msg, Session)
            || {deliver, Topic, Msg} <- Delivers],
    lists:foldl(fun enqueue/2, Session, Msgs);

enqueue(Msg, Session = #session{mqueue = Q, enqueue_cnt = Cnt})
  when is_record(Msg, message) ->
    {Dropped, NewQ} = emqx_mqueue:in(Msg, Q),
    if is_record(Dropped, message) ->
           ?LOG(warning, "Dropped msg due to mqueue is full: ~s",
                [emqx_message:format(Dropped)]);
       true -> ok
    end,
    Session#session{mqueue = NewQ, enqueue_cnt = Cnt+1}.

%%--------------------------------------------------------------------
%% Awaiting ACK for QoS1/QoS2 Messages
%%--------------------------------------------------------------------

await(PacketId, Msg, Session = #session{inflight = Inflight}) ->
    Inflight1 = emqx_inflight:insert(PacketId, {Msg, os:timestamp()}, Inflight),
    Session#session{inflight = Inflight1}.

get_subopts(Topic, SubMap) ->
    case maps:find(Topic, SubMap) of
        {ok, #{nl := Nl, qos := QoS, rap := Rap, subid := SubId}} ->
            [{nl, Nl}, {qos, QoS}, {rap, Rap}, {subid, SubId}];
        {ok, #{nl := Nl, qos := QoS, rap := Rap}} ->
            [{nl, Nl}, {qos, QoS}, {rap, Rap}];
        error -> []
    end.

enrich_subopt([], Msg, _Session) -> Msg;
enrich_subopt([{nl, 1}|Opts], Msg, Session) ->
    enrich_subopt(Opts, emqx_message:set_flag(nl, Msg), Session);
enrich_subopt([{nl, 0}|Opts], Msg, Session) ->
    enrich_subopt(Opts, Msg, Session);
enrich_subopt([{qos, SubQoS}|Opts], Msg = #message{qos = PubQoS},
              Session = #session{upgrade_qos= true}) ->
    enrich_subopt(Opts, Msg#message{qos = max(SubQoS, PubQoS)}, Session);
enrich_subopt([{qos, SubQoS}|Opts], Msg = #message{qos = PubQoS},
              Session = #session{upgrade_qos= false}) ->
    enrich_subopt(Opts, Msg#message{qos = min(SubQoS, PubQoS)}, Session);
enrich_subopt([{rap, 1}|Opts], Msg, Session) ->
    enrich_subopt(Opts, Msg, Session);
enrich_subopt([{rap, 0}|Opts], Msg = #message{headers = #{retained := true}}, Session) ->
    enrich_subopt(Opts, Msg, Session);
enrich_subopt([{rap, 0}|Opts], Msg, Session) ->
    enrich_subopt(Opts, emqx_message:set_flag(retain, false, Msg), Session);
enrich_subopt([{subid, SubId}|Opts], Msg, Session) ->
    Msg1 = emqx_message:set_header('Subscription-Identifier', SubId, Msg),
    enrich_subopt(Opts, Msg1, Session).

%%--------------------------------------------------------------------
%% Retry Delivery
%%--------------------------------------------------------------------

%% Redeliver at once if force is true
retry(Session = #session{inflight = Inflight}) ->
    case emqx_inflight:is_empty(Inflight) of
        true  -> {ok, Session};
        false ->
            SortFun = fun({_, {_, Ts1}}, {_, {_, Ts2}}) -> Ts1 < Ts2 end,
            Msgs = lists:sort(SortFun, emqx_inflight:to_list(Inflight)),
            retry_delivery(Msgs, os:timestamp(), [], Session)
    end.

retry_delivery([], _Now, Acc, Session) ->
    %% Retry again...
    {ok, lists:reverse(Acc), Session};

retry_delivery([{PacketId, {Val, Ts}}|More], Now, Acc,
               Session = #session{retry_interval = Interval,
                                  inflight = Inflight}) ->
    %% Microseconds -> MilliSeconds
    Age = timer:now_diff(Now, Ts) div 1000,
    if
        Age >= Interval ->
            {Acc1, Inflight1} = retry_delivery(PacketId, Val, Now, Acc, Inflight),
            retry_delivery(More, Now, Acc1, Session#session{inflight = Inflight1});
        true ->
            {ok, lists:reverse(Acc), Interval - max(0, Age), Session}
    end.

retry_delivery(PacketId, Msg, Now, Acc, Inflight) when is_record(Msg, message) ->
    case emqx_message:is_expired(Msg) of
        true ->
            ok = emqx_metrics:inc('messages.expired'),
            {Acc, emqx_inflight:delete(PacketId, Inflight)};
        false ->
            Msg1 = emqx_message:set_flag(dup, true, Msg),
            {[{publish, PacketId, Msg1}|Acc],
             emqx_inflight:update(PacketId, {Msg1, Now}, Inflight)}
    end;

retry_delivery(PacketId, pubrel, Now, Acc, Inflight) ->
    Inflight1 = emqx_inflight:update(PacketId, {pubrel, Now}, Inflight),
    {[{pubrel, PacketId}|Acc], Inflight1}.

%%--------------------------------------------------------------------
%% Expire Awaiting Rel
%%--------------------------------------------------------------------

expire(awaiting_rel, Session = #session{awaiting_rel = AwaitingRel}) ->
    case maps:size(AwaitingRel) of
        0 -> {ok, Session};
        _ ->
            AwaitingRel1 = lists:keysort(2, maps:to_list(AwaitingRel)),
            expire_awaiting_rel(AwaitingRel1, os:timestamp(), Session)
    end.

expire_awaiting_rel([], _Now, Session) ->
    {ok, Session};

expire_awaiting_rel([{PacketId, Ts} | More], Now,
                    Session = #session{awaiting_rel = AwaitingRel,
                                       await_rel_timeout = Timeout}) ->
    case (timer:now_diff(Now, Ts) div 1000) of
        Age when Age >= Timeout ->
            ok = emqx_metrics:inc('messages.qos2.expired'),
            ?LOG(warning, "Dropped qos2 packet ~s for await_rel_timeout", [PacketId]),
            Session1 = Session#session{awaiting_rel = maps:remove(PacketId, AwaitingRel)},
            expire_awaiting_rel(More, Now, Session1);
        Age ->
            {ok, Timeout - max(0, Age), Session}
    end.

%%--------------------------------------------------------------------
%% Next Packet Id
%%--------------------------------------------------------------------

next_pkt_id(Session = #session{next_pkt_id = 16#FFFF}) ->
    Session#session{next_pkt_id = 1};

next_pkt_id(Session = #session{next_pkt_id = Id}) ->
    Session#session{next_pkt_id = Id + 1}.

