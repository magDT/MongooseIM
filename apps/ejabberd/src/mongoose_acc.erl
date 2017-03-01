%%%-------------------------------------------------------------------
%%%
%%% This module encapsulates a data type which will initially be passed to
%%% hookhandlers as accumulator, and later will be passed all the way along
%%% processing chain.
%%%
%%%-------------------------------------------------------------------
-module(mongoose_acc).
-author("bartek").

-include("jlib.hrl").
-include("ejabberd.hrl").

%% API
-export([new/0, from_kv/2, put/3, get/2, get/3, append/3, to_map/1, remove/2]).
-export([from_element/1, from_map/1, update/2, is_acc/1]).
-export([initialise/3, terminate/3, terminate/4, dump/1, to_binary/1]).
-export_type([t/0]).

%% if it is defined as -opaque then dialyzer fails
-type t() :: map().

%%% This module encapsulates implementation of mongoose_acc
%%% its interface is map-like but implementation might change
%%% it is passed along many times, and relatively rarely read or written to
%%% might be worth reimplementing as binary

%%%%% devel API %%%%%

%%% Eventually, we'll call initialise when a stanza enters MongooseIM and terminate
%%% when it leaves. During development we can call both in arbitrary places, provided that
%%% the code which is executed between them is rewritten. We will proceed by moving
%%% both points further apart until they reach their respective ends of processing chain.

initialise(El, _F, _L) ->
%%    ?ERROR_MSG("AAA initialise accumulator ~p ~p", [F, L]),
    from_element(El).

terminate(M, _F, _L) ->
%%    ?ERROR_MSG("ZZZ terminate accumulator ~p ~p", [F, L]),
    get(element, M).

terminate(M, received, _F, _L) ->
%%    ?ERROR_MSG("ZZZ terminate accumulator ~p ~p", [F, L]),
    get(to_send, M, get(element, M)).

dump(Acc) ->
    dump(Acc, lists:sort(maps:keys(Acc))).

to_binary(#xmlel{} = Packet) ->
    ?DEPRECATED,
    exml:to_binary(Packet);
to_binary(Acc) ->
    % replacement to exml:to_binary, for error logging
    exml:to_binary(mongoose_acc:get(element, Acc)).

%% This function is for transitional period, eventually all hooks will use accumulator
%% and we will not have to check
is_acc(A) when is_map(A) ->
    maps:get(mongoose_acc, A, false);
is_acc(_) ->
    false.

%%%%% API %%%%%

-spec new() -> t().
new() ->
    #{mongoose_acc => true}.

-spec from_kv(atom(), any()) -> t().
from_kv(K, V) ->
    M = maps:put(K, V, #{}),
    maps:put(mongoose_acc, true, M).

-spec from_element(xmlel()) -> t().
from_element(El) ->
    #xmlel{name = Name, attrs = Attrs, children = Children} = El,
    Type = exml_query:attr(El, <<"type">>, undefined),
    Acc = #{element => El, mongoose_acc => true, name => Name, attrs => Attrs, type => Type},
    read_children(Acc, Children).

-spec from_map(map()) -> t().
from_map(M) ->
    maps:put(mongoose_acc, true, M).

-spec update(t(), map() | t()) -> t().
update(Acc, M) ->
    maps:merge(Acc, M).

%% @doc convert to map so that we can pattern-match on it
-spec to_map(t()) -> map()|{error, cant_convert_to_map}.
to_map(P) when is_map(P) ->
    P;
to_map(_) ->
    {error, cant_convert_to_map}.

-spec put(atom(), any(), t()) -> t().
put(Key, Val, P) ->
    maps:put(Key, Val, P).

-spec get(atom()|[atom()], t()) -> any().
get([], _) ->
    undefined;
get([Key|Keys], P) ->
    case maps:is_key(Key, P) of
        true ->
            maps:get(Key, P);
        _ ->
            get(Keys, P)
    end;
get(Key, P) ->
    maps:get(Key, P).

-spec get(atom(), t(), any()) -> any().
get(Key, P, Default) ->
    maps:get(Key, P, Default).

-spec append(atom(), any(), t()) -> t().
append(Key, Val, P) ->
    L = get(Key, P, []),
    maps:put(Key, append(Val, L), P).

-spec remove(Key :: atom(), Accumulator :: t()) -> t().
remove(Key, Accumulator) ->
    maps:remove(Key, Accumulator).

%%%%% internal %%%%%

append(Val, L) when is_list(L), is_list(Val) ->
    L ++ Val;
append(Val, L) when is_list(L) ->
    [Val | L].

dump(_, []) ->
    ok;
dump(Acc, [K|Tail]) ->
    ?ERROR_MSG("~p = ~p", [K, maps:get(K, Acc)]),
    dump(Acc, Tail).

read_children(Acc, []) ->
    Acc;
read_children(Acc, [Chld|Tail]) ->
    Acc1 = case exml_query:attr(Chld, <<"xmlns">>, undefined) of
               undefined ->
                   Acc;
               X ->
                   #xmlel{name = Name} = Chld,
                   mongoose_acc:put(command, Name, mongoose_acc:put(xmlns, X, Acc))
           end,
    read_children(Acc1, Tail).

