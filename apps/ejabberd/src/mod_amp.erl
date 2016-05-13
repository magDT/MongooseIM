-module(mod_amp).
%% @doc MongooseIM/Ejabberd module for (a subset of) XEP-0079 support.
%% @reference <a href="http://xmpp.org/extensions/xep-0079.html">XEP-0079</a>
%% @author <mongooseim@erlang-solutions.com>
%% @copyright 2014 Erlang Solutions, Ltd.
%% This work was sponsored by Grindr LLC

-behavior(gen_mod).
-xep([{xep, 79}, {version, "1.2"}, {comment, "partially implemented."}]).
-export([start/2, stop/1]).
-export([check_packet/2,
         check_packet/3,
         add_local_features/5,
         add_stream_feature/2,
         amp_check_packet/2,
         strip_amp_el_from_request/1
        ]).

-include_lib("ejabberd/include/amp.hrl").
-include_lib("ejabberd/include/ejabberd.hrl").
-include_lib("ejabberd/include/jlib.hrl").

-type hook_data() :: {jid(),#xmlel{}} | drop.

-define(AMP_FEATURE,
        #xmlel{name = <<"amp">>, attrs = [{<<"xmlns">>, ?NS_AMP_FEATURE}]}).
-define(AMP_RESOLVER, amp_resolver).
-define(AMP_STRATEGY, amp_strategy).

start(Host, _Opts) ->
    mod_disco:register_feature(Host, ?NS_AMP),
    ejabberd_hooks:add(c2s_stream_features, Host, ?MODULE, add_stream_feature, 50),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE, add_local_features, 99),
    ejabberd_hooks:add(amp_check_packet, Host, ?MODULE, amp_check_packet, 10),
    ejabberd_hooks:add(amp_verify_support, Host, ?AMP_RESOLVER, verify_support, 10),
    ejabberd_hooks:add(amp_check_condition, Host, ?AMP_RESOLVER, check_condition, 10),
    ejabberd_hooks:add(amp_determine_strategy, Host, ?AMP_STRATEGY, determine_strategy, 10).

stop(Host) ->
    ejabberd_hooks:delete(amp_determine_strategy, Host, ?AMP_STRATEGY, determine_strategy, 10),
    ejabberd_hooks:delete(amp_check_condition, Host, ?AMP_RESOLVER, check_condition, 10),
    ejabberd_hooks:delete(amp_verify_support, Host, ?AMP_RESOLVER, verify_support, 10),
    ejabberd_hooks:delete(amp_check_packet, Host, ?MODULE, amp_check_packet, 10),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, add_local_features, 99),
    ejabberd_hooks:delete(c2s_stream_features, Host, ?MODULE, add_stream_feature, 50),
    mod_disco:unregister_feature(Host, ?NS_AMP).

%% Business API
check_packet(Packet = #xmlel{attrs = Attrs}, Event) ->
    case xml:get_attr(<<"from">>, Attrs) of
        {value, From} ->
            check_packet(Packet, Event, jid:from_binary(From));
        _ ->
            ok
    end.

check_packet(Packet, Event, #jid{lserver = Host} = From) ->
    HookData = {From, Packet},
    ejabberd_hooks:run_fold(amp_check_packet, Host, HookData, [Event]).

add_local_features(Acc, _From, _To, ?NS_AMP, _Lang) ->
    Features = result_or(Acc, []) ++ amp_features(),
    {result, Features};
add_local_features(Acc, _From, _To, _NS, _Lang) ->
    Acc.

add_stream_feature(Acc, _Host) ->
    lists:keystore(<<"amp">>, #xmlel.name, Acc, ?AMP_FEATURE).

-spec amp_check_packet(hook_data(), atom()) -> hook_data().
amp_check_packet(drop, _) -> drop;
amp_check_packet({From, #xmlel{name = <<"message">>} = Packet} = HookData, Event) ->
    ?DEBUG("handle event ~p for packet ~p from ~p", [Packet, From]),
    case amp:extract_requested_rules(Packet) of
        none                    -> HookData;
        {rules, Rules}          -> process_amp_rules(HookData, Rules, Event);
        {errors, Errors}        -> send_errors_and_drop(HookData, Errors)
    end;
amp_check_packet(HookData, _Event) -> HookData.

strip_amp_el_from_request(Packet) ->
    case amp:is_amp_request(Packet) of
        true -> amp:strip_amp_el(Packet);
        false -> Packet
    end.

%% @doc This may eventually be configurable, but for now we return a constant list.
amp_features() ->
    [<<"http://jabber.org/protocol/amp">>
    ,<<"http://jabber.org/protocol/amp?action=notify">>
    ,<<"http://jabber.org/protocol/amp?action=error">>
    ,<<"http://jabber.org/protocol/amp?condition=deliver">>
    ,<<"http://jabber.org/protocol/amp?condition=match-resource">>
    ].

-spec process_amp_rules(hook_data(), amp_rules(), atom()) -> hook_data().
process_amp_rules(HookData, Rules, Event) ->
    VerifiedRules = verify_support(hd_host(HookData), Rules),
    {Good,Bad} = lists:partition(fun is_supported_rule/1, VerifiedRules),
    ValidRules = [ Rule || {supported, Rule} <- Good ],
    case Bad of
        [{error, ValidationError, InvalidRule} | _] ->
            send_error_and_drop(HookData, ValidationError, InvalidRule);
        [] ->
            Strategy = determine_strategy(HookData, Event),
            process_one_by_one(HookData, Event, Strategy, ValidRules)
    end.

%% @doc ejabberd_hooks helpers
-spec verify_support(binary(), amp_rules()) -> [amp_rule_support()].
verify_support(Host, Rules) ->
    ejabberd_hooks:run_fold(amp_verify_support, Host, [], [Rules]).

%-spec determine_strategy(hook_data()) -> amp_strategy().
determine_strategy({From, Packet} = HookData, Event) ->
    To = message_target(HookData),
    ejabberd_hooks:run_fold(amp_determine_strategy, hd_host(HookData),
                            amp_strategy:null_strategy(), [From, To, Packet, Event]).

-spec resolve_condition(hook_data(), amp_strategy(),
                        amp_condition(), amp_value())
                       -> boolean().
resolve_condition(HookData, Strategy, Condition, Value) ->
    ejabberd_hooks:run_fold
      (amp_check_condition, hd_host(HookData), false,
       [Strategy, Condition, Value]).

-spec process_one_by_one(hook_data(), amp_value(), amp_strategy(), amp_rules()) -> hook_data().
process_one_by_one({From, Packet} = HookData, Event, Strategy, ValidRules) ->
    case {Event, Strategy#amp_strategy.status,
          fold_apply_rules(HookData, Strategy, ValidRules)} of
        {initial_check, _, 'no_match'} ->
            {From, amp:strip_amp_el(Packet)};
        {_, _, 'no_match'} ->
            {From, Packet};
        {_, _, {match, #amp_rule{action = error} = Rule}} ->
            send_error_and_drop(HookData, 'undefined-condition', Rule);
        {_, _, {match, #amp_rule{condition = deliver, value = none} = Rule}} ->
            take_action(From, Packet, Rule);
        {_, pending, {match, #amp_rule{action = notify}}} ->
            {From, Packet}; %% wait until done
        {_, done, {match, #amp_rule{action = notify} = Rule}} ->
            take_action(From, Packet, Rule);
        _ ->
            update_metric_and_drop(HookData)
    end.

-spec fold_apply_rules(hook_data(), amp_strategy(), amp_rules())
                      -> amp_rule_match().
fold_apply_rules(_, _, []) -> 'no_match';
fold_apply_rules(HookData, Strategy, [Rule|Rest]) ->
    #amp_rule{condition = C, value = V} = Rule,
    case resolve_condition(HookData, Strategy, C, V) of
        true  -> {match, Rule};
        false -> fold_apply_rules(HookData, Strategy, Rest)
    end.

-spec send_error_and_drop(hook_data(), amp_error(), amp_rule()) -> drop.
send_error_and_drop(HookData, AmpError, MatchedRule) ->
    send_errors_and_drop(HookData, [{AmpError, MatchedRule}]).

-spec send_errors_and_drop(hook_data(), [{amp_error(),amp_rule()}]) -> drop.
send_errors_and_drop(HookData, []) ->
    ?ERROR_MSG("~p generated an empty list of errors. This shouldn't happen!",
                 HookData),
    update_metric_and_drop(HookData);
send_errors_and_drop({From, Packet} = HookData, ErrorRules) ->
    Host = hd_host(HookData),
    {Errors,Rules} = lists:unzip(ErrorRules),
    ErrorResponse = amp:make_error_response(Errors, Rules, From, Packet),
    ejabberd_router:route(server_jid(From), From, ErrorResponse),
    ejabberd_hooks:run(amp_error_action_triggered, Host, [Host]),
    update_metric_and_drop(HookData).

take_action(From, Packet, #amp_rule{action = notify} = Rule) ->
    Host = hd_host({From, Packet}),
    reply_to_sender(Rule, server_jid(From), From, Packet),
    ejabberd_hooks:run(amp_notify_action_triggered, Host, [Host]),
    {From, amp:strip_amp_el(Packet)}.

-spec reply_to_sender(amp_rule(), jid(), jid(), #xmlel{}) -> ok.
reply_to_sender(MatchedRule, ServerJid, OriginalSender, OriginalPacket) ->
    Response = amp:make_response(MatchedRule, OriginalSender, OriginalPacket),
    ejabberd_router:route(ServerJid, OriginalSender, Response).


-spec update_metric_and_drop(hook_data()) -> drop.
update_metric_and_drop({From, Packet} = HookData) ->
    ejabberd_hooks:run(xmpp_stanza_dropped, hd_host(HookData),
                       [From, message_target(HookData), Packet]),
    drop.

%% Internal
result_or({result, I},_) -> I;
result_or(_, Or)         -> Or.

-spec is_supported_rule(amp_rule_support()) -> boolean().
is_supported_rule({supported, _}) -> true;
is_supported_rule(_)              -> false.

-spec hd_host(hook_data()) -> binary().
hd_host({#jid{lserver=Host}, _}) -> Host.

server_jid(#jid{lserver = Host}) ->
    jid:from_binary(Host).

-spec message_target(hook_data()) -> jid() | undefined.
message_target({_,El}) ->
    case exml_query:attr(El, <<"to">>) of
        undefined -> undefined;
        J -> jid:from_binary(J)
    end.
