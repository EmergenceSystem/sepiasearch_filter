%%%-------------------------------------------------------------------
%%% @doc PeerTube federated video agent via SepiaSearch.
%%%
%%% Searches sepiasearch.org for PeerTube videos and returns video
%%% media embryos (media_type=video) with thumbnail, watch url, duration.
%%% No embed on render. Keyless.
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(sepiasearch_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(SEARCH_URL, "https://sepiasearch.org/api/v1/search/videos?count=12&search=").
-define(UA, "sepiasearch_filter/1.0 (EmergenceSystem)").

base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"video">>, <<"videos">>, <<"film">>,
                                      <<"clip">>, <<"movie">>, <<"peertube">>,
                                      <<"watch">>, <<"media">>].

start(_Type, _Args) ->
    case sepiasearch_filter_sup:start_link() of
        {ok, Pid} -> ok = start_pop_and_http(), {ok, Pid};
        Error -> Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(sepiasearch_filter_query_listener),
    catch em_pop_sup:stop_node(sepiasearch_filter),
    ok.

start_pop_and_http() ->
    PopPort   = application:get_env(sepiasearch_filter, pop_port,   9522),
    QueryPort = application:get_env(sepiasearch_filter, query_port, 9523),
    Seeds     = application:get_env(sepiasearch_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(sepiasearch_filter),
    catch cowboy:stop_listener(sepiasearch_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(sepiasearch_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end, Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => sepiasearch_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(sepiasearch_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[sepiasearch_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

generate_embryo_list(Body) ->
    case extract_query(Body) of
        "" -> [];
        Query ->
            Url = ?SEARCH_URL ++ uri_string:quote(Query),
            Headers = [{"User-Agent", ?UA}],
            case httpc:request(get, {Url, Headers},
                               [{timeout, 8000}, {ssl, [{verify, verify_none}]}],
                               [{body_format, binary}]) of
                {ok, {{_, 200, _}, _, RBody}} ->
                    case catch json:decode(RBody) of
                        #{<<"data">> := List} when is_list(List) ->
                            lists:filtermap(fun vid_embryo/1, List);
                        _ -> []
                    end;
                _ -> []
            end
    end.

extract_query(Body) ->
    try json:decode(Body) of
        Map when is_map(Map) ->
            binary_to_list(maps:get(<<"value">>, Map,
                           maps:get(<<"query">>, Map, <<"">>)));
        _ -> binary_to_list(Body)
    catch _:_ -> binary_to_list(Body) end.

vid_embryo(#{<<"url">> := Url, <<"name">> := Name} = R)
  when is_binary(Url), is_binary(Name) ->
    Host  = get_host(R),
    Thumb = thumb_url(Host, maps:get(<<"thumbnailPath">>, R, null)),
    P0 = #{
        <<"media_type">> => <<"video">>,
        <<"title">>      => Name,
        <<"url">>        => Url,
        <<"source">>     => source_bin(Host)
    },
    P1 = put_opt(P0, <<"thumbnail">>, Thumb),
    P2 = put_opt(P1, <<"resume">>, maps:get(<<"description">>, R, null)),
    P3 = case maps:get(<<"duration">>, R, null) of
             D when is_integer(D) -> P2#{<<"duration">> => D};
             _ -> P2
         end,
    {true, #{<<"properties">> => P3}};
vid_embryo(_) -> false.

get_host(R) ->
    case maps:get(<<"account">>, R, undefined) of
        #{<<"host">> := H} when is_binary(H) -> H;
        _ ->
            case maps:get(<<"channel">>, R, undefined) of
                #{<<"host">> := H2} when is_binary(H2) -> H2;
                _ -> undefined
            end
    end.

thumb_url(Host, Path) when is_binary(Host), is_binary(Path), byte_size(Path) > 0 ->
    <<"https://", Host/binary, Path/binary>>;
thumb_url(_, _) -> null.

source_bin(undefined) -> <<"peertube">>;
source_bin(H) when is_binary(H) -> <<"peertube:", H/binary>>.

put_opt(M, _K, null)      -> M;
put_opt(M, _K, <<>>)      -> M;
put_opt(M, K, V) when is_binary(V) -> M#{K => V};
put_opt(M, _K, _)         -> M.
