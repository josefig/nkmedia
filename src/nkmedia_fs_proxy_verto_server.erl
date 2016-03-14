
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc 
-module(nkmedia_fs_proxy_verto_server).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-behaviour(nkpacket_protocol).


-export([get_all/0]).
-export([transports/1, default_port/1]).
-export([conn_init/1, conn_encode/2, conn_parse/3, conn_handle_call/4, conn_handle_info/3]).


-define(LLOG(Type, Txt, Args, State),
    lager:Type("NkMEDIA verto proxy server (~s) "++Txt, [State#state.remote | Args])).


%% ===================================================================
%% Public
%% ===================================================================

get_all() ->
    [{Local, Remote} || {Remote, Local} <- nklib_proc:values(?MODULE)].



%% ===================================================================
%% Protocol callbacks
%% ===================================================================


-record(state, {
    remote :: binary(),
    proxy :: pid()
}).


%% @private
-spec transports(nklib:scheme()) ->
    [nkpacket:transport()].

transports(_) -> [wss, ws].

-spec default_port(nkpacket:transport()) ->
    inet:port_number() | invalid.

default_port(ws) -> 8081;
default_port(wss) -> 8082.


-spec conn_init(nkpacket:nkport()) ->
    {ok, #state{}}.

conn_init(NkPort) ->
    {ok, Remote} = nkpacket:get_remote_bin(NkPort),
    State = #state{remote=Remote},
    ?LLOG(notice, "new connection (~p)", [self()], State),
    case ncs_media_fs:find_servers() of
        {ok, Servers} ->
            ?LLOG(info, "located servers: ~p", [Servers], State),
            case connect_proxy(Servers, State) of
                {ok, ProxyPid} ->
                    {ok, #state{remote=Remote, proxy=ProxyPid}};
                error ->
                    ?LLOG(warning, "no server available", [], State),
                    {stop, normal}
            end;
        {error, Error} ->
            ?LLOG(error, "error calling find_servers/0: ~p", [Error], State),
            {stop, {instance_find, Error}}
    end.


%% @private
-spec conn_parse(term()|close, nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, term(), #state{}}.

conn_parse(close, _NkPort, State) ->
    {ok, State};

conn_parse({text, <<"#S", _/binary>>=Msg}, _NkPort, #state{proxy=Pid}=State) ->
    nkmedia_fs_proxy_verto_client:send(Pid, Msg),
    {ok, State};

conn_parse({text, Data}, _NkPort, #state{proxy=Pid}=State) ->
    Msg = case nklib_json:decode(Data) of
        error ->
            ?LLOG(warning, "JSON decode error: ~p", [Data], State),
            error(json_decode);
        Json ->
            Json
    end,
    nkmedia_fs_proxy_verto_client:send(Pid, Msg),
    {ok, State}.


%% @private
-spec conn_encode(term(), nkpacket:nkport()) ->
    {ok, nkpacket:outcoming()} | continue | {error, term()}.

conn_encode(Msg, _NkPort) when is_map(Msg) ->
    Json = nklib_json:encode(Msg),
    {ok, {text, Json}};

conn_encode(Msg, _NkPort) when is_binary(Msg) ->
    {ok, {text, Msg}}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_call(term(), term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_call({nkmedia_fs_verto, _Pid, Event}, From, NkPort, State) ->
    case nkpacket_connection:send(NkPort, Event) of
        ok -> 
            gen_server:reply(From, ok),
            {ok, State};
        {error, Error} -> 
            gen_server:reply(From, error),
            ?LLOG(notice, "error sending event: ~p", [Error], State),
            {stop, normal, State}
    end;

conn_handle_call(Info, _NkPort, _From, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {ok, State}.


%% @doc Called when the connection received an erlang message
-spec conn_handle_info(term(), nkpacket:nkport(), #state{}) ->
    {ok, #state{}} | {stop, Reason::term(), #state{}}.

conn_handle_info({nkmedia_fs_verto, _Pid, Event}, NkPort, State) ->
    case nkpacket_connection:send(NkPort, Event) of
        ok -> 
            {ok, State};
        {error, Error} -> 
            ?LLOG(notice, "error sending event: ~p", [Error], State),
            {stop, normal, State}
    end;

conn_handle_info({'DOWN', _Ref, process, Pid, Reason}, _NkPort, 
                 #state{proxy=Pid}=State) ->
    ?LLOG(notice, "stopped because server stopped (~p)", [Reason], State),
    {stop, normal, State};

conn_handle_info(kill, _NkPort, _State) ->
    error(my_kill);

conn_handle_info(Info, _NkPort, State) ->
    lager:warning("Module ~p received unexpected info: ~p", [?MODULE, Info]),
    {ok, State}.



%% ===================================================================
%% Util
%% ===================================================================


%% @private
connect_proxy([], _State) ->
    error;
connect_proxy([ServerPid|Rest], State) ->
    case nkmedia_fs:start_proxy(ServerPid) of
        {ok, ProxyPid} ->
            ?LLOG(info, "connected to server ~p", [ServerPid], State),
            % ok = nkmedia_fs_server:register(ServerPid),
            monitor(process, ProxyPid),
            nklib_proc:put(?MODULE, {fs_proxy, ProxyPid}),
            {ok, ProxyPid};
        {error, Error} ->
            ?LLOG(warning, "could not start proxy: ~p", [Error], State),
            connect_proxy(Rest, State)
    end.

