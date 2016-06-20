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

%% @doc Session Management
-module(nkmedia_janus_session).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([init/3, terminate/3, start/3, update/3, answer/4, stop/3]).

-export_type([config/0, class/0, opts/0, update/0]).

-define(LLOG(Type, Txt, Args, Session),
    lager:Type("NkMEDIA JANUS Session ~s "++Txt, 
               [maps:get(id, Session) | Args])).

-include("nkmedia.hrl").

%% ===================================================================
%% Types
%% ===================================================================

-type id() :: nkmedia_session:id().
-type session() :: nkmedia_session:session().
-type continue() :: continue | {continue, list()}.


-type config() :: 
    nkmedia_session:config() |
    #{
    }.


-type class() ::
    nkmedia:class() |
    echo     |
    proxy    |
    publish  |
    listen   |
    play.

-type opts() ::
    nkmedia_session:session() |
    #{
        record => boolean(),            %
        record_file => binary(),        % echo
        room => binary(),               % publish, listen
        publisher => binary(),          % listen
        proxy_type => webrtc | rtp      % proxy
    }.


-type update() ::
    nkmedia:update() |
    {listener_switch, binary()}.


-type state() ::
    #{
        janus_id => nkmedia_janus_engine:id(),
        janus_pid => pid(),
        janus_mon => reference(),
        janus_op => answer
    }.




%% ===================================================================
%% Callbacks
%% ===================================================================


-spec init(id(), session(), state()) ->
    {ok, state()}.

init(_Id, _Session, State) ->
    {ok, State}.


%% @doc Called when the session stops
-spec terminate(Reason::term(), session(), state()) ->
    {ok, state()}.

terminate(_Reason, _Session, State) ->
    {ok, State}.


%% @private
-spec start(class(), nkmedia:session(), state()) ->
    {ok, class(), map(), none|nkmedia:offer(), none|nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

start(echo, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    case get_janus(Session, State) of
        {ok, Pid, State2} ->
            Opts = maps:with([record, record_file], Session),
            case nkmedia_janus_op:echo(Pid, Offer, Opts) of
                {ok, #{sdp:=_}=Answer} ->
                    Reply = Opts#{answer=>Answer},
                    {ok, echo, Reply, none, Answer, State2};
                {error, Error} ->
                    {error, {echo_error, Error}, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

start(echo, _Session, State) ->
    {error, missing_offer, State};

start(publish, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    try
        Room = case maps:find(room, Session) of
            {ok, Room0} -> nklib_util:to_binary(Room0);
            error -> nklib_util:uuid_4122()
        end,
        case get_janus(Session, State) of
            {ok, Pid, State2} ->
                case nkmedia_janus_room:get_info(Room) of
                    {error, not_found} ->
                        #{janus_id:=JanusId} = State2,
                        case nkmedia_janus_room:create(JanusId, Room, #{}) of
                            {ok, _} -> ok;
                            {error, Error} -> throw({room_creation_error, Error})
                        end;
                    {ok, _} ->
                        ok
                end,
                Opts = #{room=>Room},
                case nkmedia_janus_op:publish(Pid, Room, Offer, Opts) of
                    {ok, #{sdp:=_}=Answer} ->
                        Reply = Opts#{answer=>Answer},
                        {ok, publish, Reply, none, Answer, State2};
                    {error, Error2} ->
                        {error, {echo_error, Error2}, State2}
                end;
            {error, Error3} ->
                {error, Error3, State}
        end
    catch
        throw:Throw -> {error, Throw, State}
    end;

start(publish, _Session, State) ->
    {error, missing_offer, State};

start(proxy, #{offer:=#{sdp:=_}=Offer}=Session, State) ->
    case get_janus(Session, State) of
        {ok, Pid, State2} ->
            OfferType = maps:get(sdp_type, Offer, webrtc),
            OutType = maps:get(proxy_type, Session, webrtc),
            Fun = case {OfferType, OutType} of
                {webrtc, webrtc} -> videocall;
                {webrtc, rtp} -> to_sip;
                {rtp, webrtc} -> from_sip;
                {rtp, rtp} -> error
            end,
            case Fun of
                error ->
                    {error, unsupported_proxy, State};
                _ ->
                    case nkmedia_janus_op:Fun(Pid, Offer, #{}) of
                        {ok, Offer2} ->
                            State3 = State2#{janus_op=>answer},
                            Offer3 = maps:merge(Offer, Offer2),
                            Reply = #{offer=>Offer3},
                            {ok, proxy, Reply, Offer3, none, State3};
                        {error, Error} ->
                            {error, {proxy_error, Error}, State2}
                    end
            end;
        {error, Error} ->
            {error, Error, State}
    end;

start(proxy, _Session, State) ->
    {error, missing_offer, State};

start(listen, #{room:=Room, publisher:=Publisher}=Session, State) ->
    case get_janus(Session, State) of
        {ok, Pid, State2} ->
            case nkmedia_janus_op:listen(Pid, Room, Publisher, #{}) of
                {ok, Offer} ->
                    State3 = State2#{janus_op=>answer},
                    Reply = #{room=>Room, publisher=>Publisher, offer=>Offer},
                    {ok, listen, Reply, Offer, none, State3};
                {error, Error} ->
                    {error, {listen_error, Error}, State2}
            end;
        {error, Error} ->
            {error, Error, State}
    end;

start(listen, _Session, State) ->
    {error, missing_parameters, State};

start(_Class, _Session, _State) ->
    continue.


%% @private
-spec answer(nkmedia:class(), nkmedia:answer(), session(), state()) ->
    {ok, map(), nkmedia:answer(), state()} |
    {error, term(), state()} | continue().

answer(listen, Answer, _Session, #{janus_op:=answer}=State) ->
    #{janus_pid:=Pid} = State,
    case nkmedia_janus_op:answer(Pid, Answer) of
        ok ->
            {ok, #{}, Answer, maps:remove(janus_op, State)};
        {ok, Answer2} ->
            {ok, #{answer=>Answer2}, Answer, maps:remove(janus_op, State)};
        {error, Error} ->
            {error, {janus_answer_error, Error}, State}
    end;

answer(listen, _Answer, _Session, State) ->
    {error, incompatible_operation, State};

answer(_Class, _Answer, _Session, _State) ->
    continue.


%% @private
-spec update(update(), nkmedia:session(), state()) ->
    {ok, class(), map(), state()} |
    {error, term(), state()} | continue().

update(listen, {listen_switch, Publisher}, #{janus_pid:=Pid}=State) ->
    case nkmedia_janus_op:listen_switch(Pid, Publisher, #{}) of
        ok ->
            {ok, listen, #{publisher=>Publisher}, State};
        {error, Error} ->
            {error, {listen_switch_error, Error}, State}
    end;

update(_Update, _Session, _State) ->
    continue.


%% @private
-spec stop(nkmedia:stop_reason(), session(), state()) ->
    {ok, state()}.

stop(_Reason, _Session, State) ->
    {ok, State}.




%% ===================================================================
%% Internal
%% ===================================================================


%% @private
get_janus(#{id:=SessId}, #{janus_id:=JanusId}=State) ->
    case nkmedia_janus_op:start(JanusId, SessId) of
        {ok, Pid} ->
            State2 = State#{janus_pid=>Pid, janus_mon=>monitor(process, Pid)},
            {ok, Pid, State2};
        {error, Error} ->
            {error, Error, State}
    end;

get_janus(Session, State) ->
    case get_mediaserver(Session, State) of
        {ok, State2} ->
            get_janus(Session, State2);
        {error, Error} ->
            {error, {get_janus_error, Error}, State}
    end.



%% @private
-spec get_mediaserver(session(), state()) ->
    {ok, state()} | {error, term()}.

get_mediaserver(_Session, #{janus_id:=_}=State) ->
    {ok, State};

get_mediaserver(#{srv_id:=SrvId}=Session, State) ->
    case SrvId:nkmedia_janus_get_mediaserver(Session) of
        {ok, Id} ->
            {ok, State#{janus_id=>Id}};
        {error, Error} ->
            {error, Error}
    end.


% %% @private
% get_op(#{offer_op:={Op, Data}}, #{janus_role:=offer}) -> {offer_op, Op, Data};
% get_op(#{answer_op:={Op, Data}}, #{janus_role:=answer}) -> {answer_op, Op, Data};
% get_op(_, _) -> unknown_op.

