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

-module(emqx_access_control).

-include("emqx.hrl").

-export([authenticate/1]).

-export([ check_acl/3
        , reload_acl/0
        ]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec(authenticate(emqx_types:client())
      -> {ok, #{auth_result := emqx_types:auth_result(),
                anonymous := boolean}} | {error, term()}).
authenticate(Client) ->
    case emqx_hooks:run_fold('client.authenticate',
                             [Client], default_auth_result(maps:get(zone, Client, undefined))) of
    	Result = #{auth_result := success, anonymous := true} ->
            emqx_metrics:inc('auth.mqtt.anonymous'),
	        {ok, Result};
        Result = #{auth_result := success} ->
	        {ok, Result};
	    Result ->
	        {error, maps:get(auth_result, Result, unknown_error)}
    end.

%% @doc Check ACL
-spec(check_acl(emqx_types:cient(), emqx_types:pubsub(), emqx_types:topic())
      -> allow | deny).
check_acl(Client, PubSub, Topic) ->
    case emqx_acl_cache:is_enabled() of
        true ->
            check_acl_cache(Client, PubSub, Topic);
        false ->
            do_check_acl(Client, PubSub, Topic)
    end.

check_acl_cache(Client, PubSub, Topic) ->
    case emqx_acl_cache:get_acl_cache(PubSub, Topic) of
        not_found ->
            AclResult = do_check_acl(Client, PubSub, Topic),
            emqx_acl_cache:put_acl_cache(PubSub, Topic, AclResult),
            AclResult;
        AclResult -> AclResult
    end.

do_check_acl(#{zone := Zone} = Client, PubSub, Topic) ->
    Default = emqx_zone:get_env(Zone, acl_nomatch, deny),
    case emqx_hooks:run_fold('client.check_acl', [Client, PubSub, Topic], Default) of
        allow  -> allow;
        _Other -> deny
    end.

-spec(reload_acl() -> ok | {error, term()}).
reload_acl() ->
    emqx_acl_cache:is_enabled()
        andalso emqx_acl_cache:empty_acl_cache(),
    emqx_mod_acl_internal:reload_acl().

default_auth_result(Zone) ->
    case emqx_zone:get_env(Zone, allow_anonymous, false) of
	    true  -> #{auth_result => success, anonymous => true};
	    false -> #{auth_result => not_authorized, anonymous => false}
    end.

