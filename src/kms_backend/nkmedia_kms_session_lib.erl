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

%% @doc Session Management Utilities
-module(nkmedia_kms_session_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([kms_event/3]).
-export([get_mediaserver/1, get_pipeline/1, stop_endpoint/1]).
-export([create_webrtc/2, create_rtp/2]).
-export([add_ice_candidate/2, set_answer/2]).
-export([create_recorder/2, recorder_op/2]).
-export([create_player/3, player_op/2]).
-export([update_media/2, get_stats/2]).
-export([connect/3, disconnect_all/1, release/1]).
-export([get_create_medias/1]).
-export([invoke/3, invoke/4]).
-export([print_info/2]).

-define(LLOG(Type, Txt, Args, SessId),
    lager:Type("NkMEDIA KMS Session ~s "++Txt, [SessId| Args])).

-include_lib("nksip/include/nksip.hrl").
-include("../../include/nkmedia.hrl").

-define(MAX_ICE_TIME, 100).


%% ===================================================================
%% Types
%% ===================================================================

-type session_id() :: nkmedia_session:id().
-type session() :: nkmedia_kms_session:session().
-type endpoint() :: binary().



% AUDIO, VIDEO, DATA
-type media_type() :: nkmedia_kms_session:binary(). 



%% ===================================================================
%% External
%% ===================================================================

%% @private Called from nkmedia_kms_client when it founds a SessId in the event
-spec kms_event(session_id(), binary(), map()) ->
    ok.

kms_event(SessId, <<"OnIceCandidate">>, Data) ->
    #{
        <<"source">> := _SrcId,
        <<"candidate">> := #{
            <<"sdpMid">> := MId,
            <<"sdpMLineIndex">> := MIndex,
            <<"candidate">> := ALine
        }
    } = Data,
    Candidate = #candidate{m_id=MId, m_index=MIndex, a_line=ALine},
    nkmedia_session:server_candidate(SessId, Candidate);

kms_event(SessId, <<"OnIceGatheringDone">>, _Data) ->
    nkmedia_session:server_candidate(SessId, #candidate{last=true});

kms_event(SessId, <<"EndOfStream">>, Data) ->
    #{<<"source">>:=Player} = Data,
    nkmedia_session:do_cast(SessId, {nkmedia_kms, {end_of_stream, Player}});

kms_event(SessId, <<"Error">>, Data) ->
    #{
        <<"description">> := Desc,
        <<"errorCode">> := Code, 
        <<"type">> := Type              % <<"INVALID_URI">>
    } = Data,
    nkmedia_session:do_cast(SessId, {nkmedia_kms, {kms_error, Type, Code, Desc}});

kms_event(SessId, Type, Data) ->
    print_event(SessId, Type, Data).




%% ===================================================================
%% Public
%% ===================================================================

%% @private
-spec get_mediaserver(session()) ->
    {ok, session()} | {error, nkservice:error()}.

get_mediaserver(#{nkmedia_kms_id:=_}=Session) ->
    {ok, Session};

get_mediaserver(#{srv_id:=SrvId}=Session) ->
    case SrvId:nkmedia_kms_get_mediaserver(SrvId) of
        {ok, KmsId} ->
            get_pipeline(?SESSION(Session, #{nkmedia_kms_id=>KmsId}));
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec get_pipeline(session()) ->
    {ok, session()} | {error, nkservice:error()}.

get_pipeline(#{nkmedia_kms_id:=KmsId}=Session) ->
    case nkmedia_kms_engine:get_pipeline(KmsId) of
        {ok, Pipeline} ->
            {ok, ?SESSION(Session, #{nkmedia_kms_pipeline=>Pipeline})};
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec stop_endpoint(session()) ->
    ok.

stop_endpoint(Session) ->
    release(Session).


%% @private
-spec create_webrtc(nkmedia:offer()|#{}, session()) ->
    {ok, nkmedia:offer()|nkmedia:answer(), session()} | {error, nkservice:error()}.

create_webrtc(Offer, Session) ->
    case create_endpoint('WebRtcEndpoint', #{}, Session) of
        {ok, EP} ->
            Upd = #{nkmedia_kms_endpoint=>EP, nkmedia_kms_endpoint_type=>webrtc},
            Session2 = ?SESSION(Session, Upd),
            subscribe('Error', Session2),
            subscribe('OnIceComponentStateChanged', Session2),
            subscribe('OnIceCandidate', Session2),
            subscribe('OnIceGatheringDone', Session2),
            subscribe('NewCandidatePairSelected', Session2),
            subscribe('MediaStateChanged', Session2),
            subscribe('MediaFlowInStateChange', Session2),
            subscribe('MediaFlowOutStateChange', Session2),
            subscribe('ConnectionStateChanged', Session2),
            subscribe('ElementConnected', Session2),
            subscribe('ElementDisconnected', Session2),
            subscribe('MediaSessionStarted', Session2),
            subscribe('MediaSessionTerminated', Session2),
            case Offer of
                #{sdp:=SDP} ->
                    {ok, SDP2} = invoke(processOffer, #{offer=>SDP}, Session2);
                _ ->
                    {ok, SDP2} = invoke(generateOffer, #{}, Session2)
            end,
            ok = invoke(gatherCandidates, #{}, Session2),
            {ok, Offer#{sdp=>SDP2, trickle_ice=>true, sdp_type=>webrtc}, Session2};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec create_rtp(nkmedia:offer()|#{}, session()) ->
    {ok, nkmedia:offer()|nkmedia:answer(), session()} | {error, nkservice:error()}.

create_rtp(Offer, Session) ->
    case create_endpoint('RtpEndpoint', #{}, Session) of
        {ok, EP} ->
            Upd = #{nkmedia_kms_endpoint=>EP, nkmedia_kms_endpoint_type=>rtp},
            Session2 = ?SESSION(Session, Upd),
            subscribe('Error', Session2),
            subscribe('MediaStateChanged', Session2),
            subscribe('MediaFlowInStateChange', Session2),
            subscribe('MediaFlowOutStateChange', Session2),
            subscribe('ConnectionStateChanged', Session2),
            subscribe('ElementConnected', Session2),
            subscribe('ElementDisconnected', Session2),
            subscribe('MediaSessionStarted', Session2),
            subscribe('MediaSessionTerminated', Session2),
            case Offer of
                #{offer:=#{sdp:=SDP}} ->
                    {ok, SDP2} = invoke(processOffer, #{offer=>SDP}, Session2);
                _ ->
                    {ok, SDP2} = invoke(generateOffer, #{}, Session2)
            end,
            {ok, Offer#{sdp=>SDP2, sdp_type=>rtp}, Session2};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec set_answer(nkmedia:answer(), session()) ->
    ok | {error, nkservice:error()}.

set_answer(#{sdp:=SDP}, Session) ->
    invoke(processAnswer, #{offer=>SDP}, Session).


%% @private
-spec add_ice_candidate(nkmedia:candidate(), session()) ->
    ok | {error, nkservice:error()}.

add_ice_candidate(Candidate, Session) ->
    #candidate{m_id=MId, m_index=MIndex, a_line=ALine} = Candidate,
    Data = #{
        sdpMid => MId,
        sdpMLineIndex => MIndex,
        candidate => ALine
    },
    ok = invoke(addIceCandidate, #{candidate=>Data}, Session).




%% @private
%% Recorder supports record, pause, stop, stopAndWait
%% Profiles: KURENTO_SPLIT_RECORDER , MP4, MP4_AUDIO_ONLY, MP4_VIDEO_ONLY, 
%%           WEBM, WEBM_AUDIO_ONLY, WEBM_VIDEO_ONLY, JPEG_VIDEO_ONLY
-spec create_recorder(map(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

create_recorder(Opts, #{nkmedia_kms_recorder:=_}=Session) ->
    {ok, Session2} = recorder_op(stop, Session),
    create_recorder(Opts, ?SESSION_RM(nkmedia_kms_recorder, Session2));

create_recorder(Opts, #{nkmedia_kms_endpoint:=EP}=Session) ->
    Medias = lists:flatten([
        case maps:get(use_audio, Opts, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Opts, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end
    ]),
    {Uri, Session2} = case maps:find(uri, Opts) of
        {ok, Uri0} -> {Uri0, Session};
        error -> make_record_uri(Session)
    end,
    Profile = maps:get(mediaProfile, Opts, <<"WEBM">>),
    Params = #{uri=>nklib_util:to_binary(Uri), mediaProfile=>Profile},
    lager:notice("Started recording: ~p", [Params]),
    case create_endpoint('RecorderEndpoint', Params, Session2) of
        {ok, ObjId} ->
            subscribe(ObjId, 'Error', Session2),
            subscribe(ObjId, 'Paused', Session2),
            subscribe(ObjId, 'Stopped', Session2),
            subscribe(ObjId, 'Recording', Session2),
            ok = do_connect(EP, ObjId, Medias, Session2),
            ok = invoke(ObjId, record, #{}, Session2),
            {ok, ?SESSION(Session2, #{nkmedia_kms_recorder=>ObjId})};
        {error, Error} ->
           {error, Error}
    end.


%% @private
-spec make_record_uri(session()) ->
    {binary(), session()}.

make_record_uri(#{session_id:=SessId}=Session) ->
    Pos = maps:get(nkmedia_kms_record_pos, Session, 0),
    Name = io_lib:format("~s_p~4..0w.webm", [SessId, Pos]),
    File = filename:join(<<"/tmp/record">>, list_to_binary(Name)),
    {<<"file://", File/binary>>, ?SESSION(Session, #{record_pos=>Pos+1})}.


%% @private
-spec recorder_op(atom(), session()) ->
    {ok, session()} | {error, nkservice:error()}.

recorder_op(pause, #{nkmedia_kms_recorder:=RecorderEP}=Session) ->
    ok = invoke(RecorderEP, pause, #{}, Session),
    {ok, Session};

recorder_op(resume, #{nkmedia_kms_recorder:=RecorderEP}=Session) ->
    ok = invoke(RecorderEP, record, #{}, Session),
    {ok, Session};

recorder_op(stop, #{nkmedia_kms_recorder:=RecorderEP}=Session) ->
    invoke(RecorderEP, stop, #{}, Session),
    release(RecorderEP, Session),
    {ok, ?SESSION_RM(nkmedia_kms_recorder, Session)};

recorder_op(_, #{nkmedia_kms_recorder:=_}) ->
    {error, invalid_operation};

recorder_op(_, _Session) ->
    {error, no_active_recorder}.


%% @private
%% Player supports play, pause, stop, getPosition, getVideoInfo, setPosition (position)
-spec create_player(binary(), map(), session()) ->
    {ok, session()} | {error, nkservice:error(), session()}.

create_player(Uri, Opts, #{player:=_}=Session) ->
    {ok, Session2} = player_op(stop, Session),
    create_player(Uri, Opts, ?SESSION_RM(nkmedia_kms_player, Session2));

create_player(Uri, Opts, #{endpoint:=EP}=Session) ->
    Medias = lists:flatten([
        case maps:get(use_audio, Opts, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Opts, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end
    ]),
    Params = #{uri=>nklib_util:to_binary(Uri)},
    case create_endpoint('PlayerEndpoint', Params, Session) of
        {ok, ObjId} ->
            subscribe(ObjId, 'Error', Session),
            subscribe(ObjId, 'EndOfStream', Session),
            ok = do_connect(ObjId, EP, Medias, Session),
            ok = invoke(ObjId, play, #{}, Session),
            {ok, ?SESSION(Session, #{nkmedia_kms_player=>ObjId})};
        {error, Error} ->
           {error, Error, Session}
    end.


%% @private
-spec player_op(term(), session()) ->
    {ok, session()} | {ok, term(), session()} | {error, nkservice:error()}.

player_op(pause, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    ok = invoke(PlayerEP, pause, #{}, Session),
    {ok, Session};

player_op(resume, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    ok = invoke(PlayerEP, play, #{}, Session),
    {ok, Session};

player_op(stop, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    invoke(PlayerEP, stop, #{}, Session),
    release(PlayerEP, Session),
    {ok, maps:remove(nkmedia_kms_player, Session)};

player_op(get_info, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    {ok, Data} = invoke(PlayerEP, getVideoInfo, #{}, Session),
    case Data of
        #{
            <<"duration">> := Duration,
            <<"isSeekable">> := IsSeekable,
            <<"seekableInit">> := Start,
            <<"seekableEnd">> := Stop
        } ->
            Data2 = #{
                duration => Duration,
                is_seekable => IsSeekable,
                first_position => Start,
                last_position => Stop
            },
            {ok, #{player_info=>Data2}, Session};
        _ ->
            lager:error("Unknown player info: ~p", [Data]),
            {ok, #{}, Session}
    end;

player_op(get_position, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    case invoke(PlayerEP, getPosition, #{}, Session) of
        {ok, Pos}  ->
            {ok, #{position=>Pos}, Session};
        {error, Error} ->
            {error, Error}
    end;

player_op({set_position, Pos}, #{nkmedia_kms_player:=PlayerEP}=Session) ->
    case invoke(PlayerEP, setPosition, #{position=>Pos}, Session) of
        ok ->
            {ok, Session};
        {error, Error} ->
            {error, Error}
    end;

player_op(_, #{nkmedia_kms_player:=_}) ->
    {error, invalid_operation};

player_op(_, _Session) ->
    {error, no_active_player}.


%% @private
-spec get_stats(binary(), session()) ->
    {ok, map()}.

get_stats(Type, Session) 
        when Type == <<"AUDIO">>; Type == <<"VIDEO">>; Type == <<"DATA">> ->
    {ok, _Stats} = invoke(getStats, #{mediaType=>Type}, Session);

get_stats(Type, _Session) ->
    {error, {invalid_value, Type}}.


%% @private
-spec create_endpoint(atom(), map(), session()) ->
    {ok, endpoint()} | {error, nkservice:error()}.

create_endpoint(Type, Params, Session) ->
    #{
        session_id := SessId,
        nkmedia_kms_id := KmsId, 
        nkmedia_kms_pipeline := Pipeline
    } = Session,
    Params2 = Params#{mediaPipeline=>Pipeline},
    Properties = #{pkey1 => pval1},
    case nkmedia_kms_client:create(KmsId, Type, Params2, Properties) of
        {ok, ObjId} ->
            ok = invoke(ObjId, addTag, #{key=>nkmedia, value=>SessId}, Session),
            ok = invoke(ObjId, setSendTagsInEvents, #{sendTagsInEvents=>true}, Session),
            {ok, ObjId};
        {error, Error} ->
            {error, Error}
    end.



%% @private
%% If you remove all medias, you can not connect again any media
%% (the hole connection is d)
-spec update_media(map(), session()) ->
    ok.

update_media(Opts, #{nkmedia_kms_endpoint:=EP}=Session) ->
    case get_update_medias(Opts) of
        {[], []} ->
            ok;
        {Add, Remove} ->
            lists:foreach(
                fun(PeerEP) ->
                    % lager:error("Source ~s: A: ~p, R: ~p", [PeerEP, Add, Remove]),
                    do_connect(PeerEP, EP, Add, Session),
                    do_disconnect(PeerEP, EP, Remove, Session)
                end,
                maps:keys(get_sources(Session))),
            lists:foreach(
                fun(PeerEP) ->
                    % lager:error("Sink ~s: A: ~p, R: ~p", [PeerEP, Add, Remove]),
                    do_connect(EP, PeerEP, Add, Session),
                    do_disconnect(EP, PeerEP, Remove, Session)
                end,
                maps:keys(get_sinks(Session)))
    end.


%% @private
%% Connects a remote Endpoint to us as sink
%% We can select the medias to use, or use a map() with options, and all medias
%% will be include except the ones that have 'use' false.
-spec connect(endpoint(), [media_type()], session()) ->
    ok | {error, nkservice:error()}.

connect(PeerEP, Opts, Session) when is_map(Opts) ->
    Medias = get_create_medias(Opts),
    connect(PeerEP, Medias, Session);

connect(PeerEP, [<<"AUDIO">>, <<"VIDEO">>, <<"DATA">>], #{nkmedia_kms_endpoint:=EP}=Session) ->
    invoke(PeerEP, connect, #{sink=>EP}, Session);

connect(PeerEP, Medias, #{nkmedia_kms_endpoint:=EP}=Session) ->
    Res = do_connect(PeerEP, EP, Medias, Session),
    Medias2 = [<<"AUDIO">>, <<"DATA">>, <<"VIDEO">>] -- lists:sort(Medias),
    do_disconnect(PeerEP, EP, Medias2, Session),
    Res.


%% @private
do_connect(_PeerEP, _SinkEP, [], _Session) ->
    ok;
do_connect(PeerEP, SinkEP, [Type|Rest], Session) ->
    case invoke(PeerEP, connect, #{sink=>SinkEP, mediaType=>Type}, Session) of
        ok ->
            lager:info("connecting ~s", [Type]),
            do_connect(PeerEP, SinkEP, Rest, Session);
        {error, Error} ->
            {error, Error}
    end.

%% @private
do_disconnect(_PeerEP, _SinkEP, [], _Session) ->
    ok;
do_disconnect(PeerEP, SinkEP, [Type|Rest], Session) ->
    case invoke(PeerEP, disconnect, #{sink=>SinkEP, mediaType=>Type}, Session) of
        ok ->
            lager:info("disconnecting ~s", [Type]),
            do_disconnect(PeerEP, SinkEP, Rest, Session);
        {error, Error} ->
            {error, Error}
    end.


%% @private
-spec disconnect_all(session()) ->
    ok.

disconnect_all(#{nkmedia_kms_endpoint:=EP}=Session) ->
    lists:foreach(
        fun(PeerEP) -> invoke(PeerEP, disconnect, #{sink=>EP}, Session) end,
        maps:keys(get_sources(Session))),
    lists:foreach(
        fun(PeerEP) -> invoke(EP, disconnect, #{sink=>PeerEP}, Session) end,
        maps:keys(get_sinks(Session)));

disconnect_all(_Session) ->
    ok.


%% @private
-spec subscribe(atom(), session()) ->
    SubsId::binary().

subscribe(Type, #{nkmedia_kms_endpoint:=EP}=Session) ->
    subscribe(EP, Type, Session).


%% @private
-spec subscribe(endpoint(), atom(), session()) ->
    SubsId::binary().

subscribe(ObjId, Type, #{nkmedia_kms_id:=KmsId}) ->
    {ok, SubsId} = nkmedia_kms_client:subscribe(KmsId, ObjId, Type),
    SubsId.


%% @private
-spec invoke(atom(), map(), session()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(Op, Params, #{nkmedia_kms_endpoint:=EP}=Session) ->
    invoke(EP, Op, Params, Session).


%% @private
-spec invoke(endpoint(), atom(), map(), session()) ->
    ok | {ok, term()} | {error, nkservice:error()}.

invoke(ObjId, Op, Params, #{nkmedia_kms_id:=KmsId}) ->
    case nkmedia_kms_client:invoke(KmsId, ObjId, Op, Params) of
        {ok, null} -> ok;
        {ok, Other} -> {ok, Other};
        {error, Error} -> {error, Error}
    end.


%% @private
-spec release(session()) ->
    ok | {error, nkservice:error()}.
 
release(#{nkmedia_kms_endpoint:=EP}=Session) ->
    release(EP, Session);
release(_Session) ->
    ok.


%% @private
-spec release(binary(), session()) ->
    ok | {error, nkservice:error()}.
 
release(ObjId, #{nkmedia_kms_id:=KmsId}) ->
    nkmedia_kms_client:release(KmsId, ObjId).


%% @private
-spec get_sources(session()) ->
    #{endpoint() => [media_type()]}.

get_sources(#{nkmedia_kms_endpoint:=EP}=Session) ->
    {ok, Sources} = invoke(getSourceConnections, #{}, Session),
    lists:foldl(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}, Acc) ->
            Sink = EP,
            Types = maps:get(Source, Acc, []),
            maps:put(Source, lists:sort([Type|Types]), Acc)
        end,
        #{},
        Sources).


%% @private
-spec get_sinks(session()) ->
    #{endpoint() => [media_type()]}.

get_sinks(#{nkmedia_kms_endpoint:=EP}=Session) ->
    {ok, Sinks} = invoke(getSinkConnections, #{}, Session),
    lists:foldl(
        fun(#{<<"type">>:=Type, <<"source">>:=Source, <<"sink">>:=Sink}, Acc) ->
            Source = EP,
            Types = maps:get(Sink, Acc, []),
            maps:put(Sink, lists:sort([Type|Types]), Acc)
        end,
        #{},
        Sinks).


%% @private
%% All medias will be included, except if "use_XXX=false"
-spec get_create_medias(map()) ->
    [media_type()].

get_create_medias(Opts) ->
    lists:flatten([
        case maps:get(use_audio, Opts, true) of
            true -> <<"AUDIO">>;
            _ -> []
        end,
        case maps:get(use_video, Opts, true) of
            true -> <<"VIDEO">>;
            _ -> []
        end,
        case maps:get(use_data, Opts, true) of
            true -> <<"DATA">>;
            _ -> []
        end
    ]).


-spec get_update_medias(map()) ->
    {[media_type()], [media_type()]}.

get_update_medias(Opts) ->
    Audio = maps:get(use_audio, Opts, none),
    Video = maps:get(use_video, Opts, none),
    Data = maps:get(use_data, Opts, none),
    Add = lists:flatten([
        case Audio of true -> <<"AUDIO">>; _ -> [] end,
        case Video of true -> <<"VIDEO">>; _ -> [] end,
        case Data of true -> <<"DATA">>; _ -> [] end
    ]),
    Rem = lists:flatten([
        case Audio of false -> <<"AUDIO">>; _ -> [] end,
        case Video of false -> <<"VIDEO">>; _ -> [] end,
        case Data of false -> <<"DATA">>; _ -> [] end
    ]),
    {Add, Rem}.


%% @private
get_id(List) when is_list(List) ->
    nklib_util:bjoin([get_id(Id) || Id <- lists:sort(List), is_binary(Id)]);

get_id(Ep) when is_binary(Ep) ->
    case binary:split(Ep, <<"/">>) of
        [_, Id] -> Id;
        _ -> Ep
    end.


%% @private
print_info(SessId, #{nkmedia_kms_endpoint:=EP}=Session) ->
    io:format("Id: ~s\n", [SessId]),
    io:format("EP: ~s\n", [get_id(EP)]),
    io:format("\nSources:\n"),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [get_id(Id), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sources(Session))),
    io:format("\nSinks:\n"),
    lists:foreach(
        fun({Id, Types}) -> 
            io:format("~s: ~s\n", [get_id(Id), nklib_util:bjoin(Types)]) 
        end,
        maps:to_list(get_sinks(Session))),

    {ok, MediaSession} = invoke(getMediaSession, #{}, Session),
    io:format("\nMediaSession: ~s\n", [MediaSession]),
    {ok, ConnectionSession} = invoke(getConnectionSession, #{}, Session),
    io:format("ConnectionSession: ~s\n", [ConnectionSession]),

    {ok, IsMediaFlowingIn1} = invoke(isMediaFlowingIn, #{mediaType=>'AUDIO'}, Session),
    io:format("IsMediaFlowingIn AUDIO: ~p\n", [IsMediaFlowingIn1]),
    {ok, IsMediaFlowingOut1} = invoke(isMediaFlowingOut, #{mediaType=>'AUDIO'}, Session),
    io:format("IsMediaFlowingOut AUDIO: ~p\n", [IsMediaFlowingOut1]),
    {ok, IsMediaFlowingIn2} = invoke(isMediaFlowingIn, #{mediaType=>'VIDEO'}, Session),
    io:format("IsMediaFlowingIn VIDEO: ~p\n", [IsMediaFlowingIn2]),
    {ok, IsMediaFlowingOut2} = invoke(isMediaFlowingOut, #{mediaType=>'VIDEO'}, Session),
    io:format("IsMediaFlowingOut VIDEO: ~p\n", [IsMediaFlowingOut2]),

    {ok, MinVideoRecvBandwidth} = invoke(getMinVideoRecvBandwidth, #{}, Session),
    io:format("MinVideoRecvBandwidth: ~p\n", [MinVideoRecvBandwidth]),
    {ok, MinVideoSendBandwidth} = invoke(getMinVideoSendBandwidth, #{}, Session),
    io:format("MinVideoSendBandwidth: ~p\n", [MinVideoSendBandwidth]),
    {ok, MaxVideoRecvBandwidth} = invoke(getMaxVideoRecvBandwidth, #{}, Session),
    io:format("MaxVideoRecvBandwidth: ~p\n", [MaxVideoRecvBandwidth]),
    {ok, MaxVideoSendBandwidth} = invoke(getMaxVideoSendBandwidth, #{}, Session),
    io:format("MaxVideoSendBandwidth: ~p\n", [MaxVideoSendBandwidth]),
    
    {ok, MaxAudioRecvBandwidth} = invoke(getMaxAudioRecvBandwidth, #{}, Session),
    io:format("MaxAudioRecvBandwidth: ~p\n", [MaxAudioRecvBandwidth]),
    
    {ok, MinOutputBitrate} = invoke(getMinOutputBitrate, #{}, Session),
    io:format("MinOutputBitrate: ~p\n", [MinOutputBitrate]),
    {ok, MaxOutputBitrate} = invoke(getMaxOutputBitrate, #{}, Session),
    io:format("MaxOutputBitrate: ~p\n", [MaxOutputBitrate]),

    % {ok, RembParams} = invoke(getRembParams, #{}, Session),
    % io:format("\nRembParams: ~p\n", [RembParams]),
    
    % Convert with dot -Tpdf gstreamer.dot -o 1.pdf
    % {ok, GstreamerDot} = invoke(getGstreamerDot, #{}, Session),
    % file:write_file("/tmp/gstreamer.dot", GstreamerDot),
    ok.



%% @private
-spec print_event(session_id(), binary(), map()) ->
    ok.

print_event(SessId, <<"OnIceComponentSessionChanged">>, Data) ->
    #{
        <<"source">> := _SrcId,
        <<"state">> := IceSession,
        <<"streamId">> := StreamId,
        <<"componentId">> := CompId
    } = Data,
    {Level, Msg} = case IceSession of
        <<"GATHERING">> -> {info, gathering};
        <<"CONNECTING">> -> {info, connecting};
        <<"CONNECTED">> -> {notice, connected};
        <<"READY">> -> {notice, ready};
        <<"FAILED">> -> {warning, failed}
    end,
    Txt = io_lib:format("ICE Session (~p:~p) ~s", [StreamId, CompId, Msg]),
    case Level of
        info ->    ?LLOG(info, "~s", [Txt], SessId);
        notice ->  ?LLOG(notice, "~s", [Txt], SessId);
        warning -> ?LLOG(warning, "~s", [Txt], SessId)
    end;

print_event(SessId, <<"MediaSessionStarted">>, _Data) ->
    ?LLOG(info, "event media session started: ~p", [_Data], SessId);

print_event(SessId, <<"ElementConnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG(info, "event element connected ~s: ~s -> ~s", 
           [Type, get_id(Source), get_id(Sink)], SessId);

print_event(SessId, <<"ElementDisconnected">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"sink">> := Sink,
        <<"source">> := Source
    } = Data,
    ?LLOG(info, "event element disconnected ~s: ~s -> ~s", 
           [Type, get_id(Source), get_id(Sink)], SessId);

print_event(SessId, <<"NewCandidatePairSelected">>, Data) ->
    #{
        <<"candidatePair">> := #{
            <<"streamID">> := StreamId,
            <<"componentID">> := CompId,
            <<"localCandidate">> := Local,
            <<"remoteCandidate">> := Remote
        }
    } = Data,
    ?LLOG(notice, "candidate selected (~p:~p) local: ~s remote: ~s", 
           [StreamId, CompId, Local, Remote], SessId);

print_event(SessId, <<"ConnectionSessionChanged">>, Data) ->
    #{
        <<"newSession">> := New,
        <<"oldSession">> := Old
    } = Data,
    ?LLOG(info, "event connection state changed (~s -> ~s)", [Old, New], SessId);

print_event(SessId, <<"MediaFlowOutSessionChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := Session
    }  = Data,
    ?LLOG(info, "event media flow out state change (~s: ~s)", [Type, Session], SessId);

print_event(SessId, <<"MediaFlowInSessionChange">>, Data) ->
    #{
        <<"mediaType">> := Type, 
        <<"padName">> := _Pad,
        <<"state">> := Session
    }  = Data,
    ?LLOG(info, "event media in out state change (~s: ~s)", [Type, Session], SessId);    

print_event(SessId, <<"MediaSessionChanged">>, Data) ->
    #{
        <<"newSession">> := New,
        <<"oldSession">> := Old
    } = Data,
    ?LLOG(info, "event media state changed (~s -> ~s)", [Old, New], SessId);

print_event(SessId, <<"Recording">>, _Data) ->
    ?LLOG(info, "event 'recording'", [], SessId);

print_event(SessId, <<"Paused">>, _Data) ->
    ?LLOG(info, "event 'paused recording'", [], SessId);

print_event(SessId, <<"Stopped">>, _Data) ->
    ?LLOG(info, "event 'stopped recording'", [], SessId);

print_event(_SessId, Type, Data) ->
    lager:warning("NkMEDIA KMS Session: unknown event ~s: ~p", [Type, Data]).
