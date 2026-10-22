%% @doc The repo's own deploy file, run through the boot path it claims to run.
%%
%% deploy/docker-compose.yml says it is runnable as-is. What decides that is the
%% release boot script: with RELX_REPLACE_OS_VARS=true (set in the Containerfile)
%% it rewrites config/sys.config.src, substituting every ${...} from the
%% environment the compose hands the container, and then erl parses the result.
%%
%% Two relx details matter here, and both were read off its own awk
%% (priv/templates/extended_bin, replace_os_vars), not assumed:
%%   * a variable with no `:-' default and no value becomes the EMPTY STRING, so
%%     `{admin_port, ${MCL_SEC_GUARD_ADMIN_PORT}}' turns into `{admin_port, }',
%%     which is not a term and the node refuses to start (that is #34);
%%   * `"${MCL_SEC_GUARD_PROPOSAL_LOG}"' in quotes becomes `""', which parses
%%     and is a log path to nowhere -- silently, so no parse-only test catches it.
%%
%% Nothing in the pipeline looked at either: eunit tests modules, not the baked
%% config, and a bad one surfaces hours later as a container that will not come
%% up. This test takes the compose file's own environment block, applies relx's
%% substitution to the template, parses the result, and asserts the two values
%% are usable -- so the file either boots or eunit says why, in this repository.
-module(mcl_sec_guard_compose_boot_tests).

-include_lib("eunit/include/eunit.hrl").

%% The four variables the compose header tells an operator to supply, given the
%% shape it names for them (64-hex realm, hex realm key, host:port seed,
%% 64-hex node id). Nothing else is invented: this is about the placeholders,
%% not about reaching a live realm.
required_env() ->
    maps:from_list(
      [{<<"MCL_REALM">>, <<"abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1">>},
       {<<"MCL_REALM_KEY">>, <<"abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1">>},
       {<<"MACULA_STATION_SEEDS">>, <<"station.example:4433">>},
       {<<"MACULA_STATION_NODE_IDS">>, <<"abb81b5a614b63551b400b810648c0c8a78efad845442630c94b46cc95d2fcd1">>}]).

%% The failure the issue was filed for: the node does not start.
compose_config_parses_test() ->
    _ = parsed_config().

%% The failure that would have survived the first fix: an empty port number.
admin_port_is_a_port_test() ->
    ?assertEqual(8458, proplists:get_value(admin_port, sec_guard_env())).

%% The other half of #34: quoted, so it parses, and points at nowhere.
proposal_log_is_the_fleet_path_test() ->
    ?assertEqual("/var/lib/mcl-sec-guard/proposals.log",
                 proplists:get_value(proposal_log, sec_guard_env())).

parsed_config() ->
    parse_term(flat(substitute(read("config/sys.config.src"), compose_env()))).

sec_guard_env() ->
    proplists:get_value(mcl_sec_guard, parsed_config()).

%% The compose file's environment block, resolved the way compose resolves it:
%% `${NAME:?why}' means the operator must set it, `${NAME:-fallback}' means use
%% the fallback when it is unset or empty, a bare `${NAME}' means the environment
%% or nothing.
compose_env() ->
    Lines = [string:trim(Line) || Line <- string:split(read("deploy/docker-compose.yml"), "\n", all)],
    maps:from_list([resolve(Entry) || Entry <- environment_entries(Lines)]).

environment_entries(Lines) ->
    {_, Entries} = lists:foldl(fun environment_entry/2, {outside, []}, Lines),
    lists:reverse(Entries).

environment_entry("environment:", {_Where, Acc}) ->
    {inside, Acc};
environment_entry(Line, {inside, Acc}) ->
    case entry(Line) of
        {ok, Entry} -> {inside, [Entry | Acc]};
        skip -> {inside, Acc};
        done -> {outside, Acc}
    end;
environment_entry(_Line, {outside, Acc}) ->
    {outside, Acc}.

%% A blank line or a comment inside the block is nothing; a `- NAME=value' line
%% is an entry; any other line closes the block (the next key in the service, or
%% the next top-level key).
entry("") -> skip;
entry("- " ++ Entry) -> {ok, Entry};
entry([$# | _]) -> skip;
entry(_Other) -> done.

resolve(Entry) ->
    [Name, Raw] = string:split(Entry, "=", leading),
    {list_to_binary(Name), list_to_binary(expand(string:trim(Raw), required_env()))}.

expand(Value, Env) ->
    case re:run(Value, "\\$\\{([^}]*)\\}", [{capture, all, list}]) of
        nomatch -> Value;
        {match, [Whole, Spec]} -> string:replace(Value, Whole, lookup(Spec, Env), all)
    end.

lookup(Spec, Env) ->
    case string:split(Spec, ":", leading) of
        [Name] -> value(Name, Env);
        [Name, "?" ++ Why] -> required(Name, Why, Env);
        [Name, "-" ++ Fallback] -> default(Name, Fallback, Env)
    end.

%% `${NAME:?why}' is compose refusing to start at all: the operator was told to
%% set this one, so the test supplies it or fails naming it.
required(Name, Why, Env) ->
    case value(Name, Env) of
        "" -> erlang:error({compose_requires, Name, Why});
        Value -> Value
    end.

default(Name, Fallback, Env) ->
    case value(Name, Env) of
        "" -> Fallback;
        Value -> Value
    end.

%% relx's own substitution, reimplemented rather than described: `${NAME:-d}'
%% takes the default when NAME is unset or empty, and `${NAME}' with no default
%% becomes the empty string when NAME is unset. Everything outside braces is
%% untouched, so comments and the rest of the file survive verbatim.
substitute(Template, Env) ->
    lists:foldl(fun(Whole, Acc) -> string:replace(Acc, Whole, os_value(Whole, Env), all) end,
                Template, placeholders(Template)).

%% The string functions work on chardata and may hand back a deep list; the
%% scanner wants one flat list of characters.
flat(Text) ->
    unicode:characters_to_list(Text).

placeholders(Template) ->
    case re:run(Template, "\\$\\{([^}]*)\\}", [global, {capture, all, list}]) of
        nomatch -> [];
        {match, Matches} -> [Whole || [Whole, _Spec] <- Matches]
    end.

os_value("${" ++ Rest, Env) ->
    Spec = lists:sublist(Rest, length(Rest) - 1),
    case string:split(Spec, ":-", leading) of
        [Name] -> value(Name, Env);
        [Name, Fallback] -> default(Name, Fallback, Env)
    end.

value(Name, Env) ->
    case maps:get(list_to_binary(Name), Env, <<>>) of
        <<>> -> "";
        Value -> binary_to_list(Value)
    end.

parse_term(Text) ->
    case erl_scan:string(Text) of
        {ok, Tokens, _} -> parse_tokens(Tokens);
        {error, {Line, Mod, Message}, _} -> scan_failed(Line, Mod, Message)
    end.

parse_tokens(Tokens) ->
    case erl_parse:parse_term(Tokens) of
        {ok, Term} ->
            Term;
        {error, {Line, Mod, Message}} ->
            erlang:error({sys_config_parse_failed, Line, lists:flatten(Mod:format_error(Message))})
    end.

scan_failed(Line, Mod, Message) ->
    erlang:error({sys_config_scan_failed, Line, lists:flatten(Mod:format_error(Message))}).

read(RelativePath) ->
    {ok, Binary} = file:read_file(filename:join(repo_root(), RelativePath)),
    binary_to_list(Binary).

%% eunit's working directory is the app's or the project's depending on how it
%% is run, so find the root by what it holds rather than by a count of "..".
repo_root() ->
    repo_root(filename:absname(".")).

repo_root(Dir) ->
    case is_repo_root(Dir) of
        true ->
            Dir;
        false ->
            case filename:dirname(Dir) of
                Dir -> erlang:error({repo_root_not_found, filename:absname(".")});
                Parent -> repo_root(Parent)
            end
    end.

is_repo_root(Dir) ->
    filelib:is_regular(filename:join([Dir, "config", "sys.config.src"]))
        andalso filelib:is_regular(filename:join([Dir, "deploy", "docker-compose.yml"])).
