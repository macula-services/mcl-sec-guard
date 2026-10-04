%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(mcl_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes mcl_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots mcl_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(mcl_sec_guard_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_sec_guard).
-define(SERVICE, mcl_sec_guard_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If mcl_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

%% THE ATTRIBUTE ITSELF. Dropped to silence a warning, it would leave compile
%% and the export check above green, and the next callback mcl_om requires
%% would be an `undef' at boot instead of a compile error.
declares_the_mcl_om_service_behaviour_test() ->
    Attrs = ?SERVICE:module_info(attributes),
    ?assert(lists:member(mcl_om_service, proplists:get_value(behaviour, Attrs, []))).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"mcl-sec-guard">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

health_is_green_test() ->
    ?assertEqual(ok, ?SERVICE:health()).

%% An empty list is the correct answer for a service that does nothing yet. The
%% assertion is here so that adding a capability breaks a test and makes someone
%% write down what the service can now actually do.
announces_no_capability_yet_test() ->
    ?assertEqual([], ?SERVICE:capabilities()).

identity_spec_has_the_shape_mcl_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% A resource this service is not authorised for is a publish the realm would
%% refuse once UCAN delegation lands. Asking for nothing and claiming nothing
%% must stay in step, so the two are asserted together.
authority_matches_what_is_announced_test() ->
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual([], ?SERVICE:capabilities()),
    ?assertEqual([], Actions),
    ?assertEqual([], Resources).

%% The supervisor starts and stops cleanly on its own, without mcl_om. In P0
%% its one child is the proposal recorder; this asserts the tree is startable
%% with exactly that child and no phantom work.
supervisor_starts_and_stops_test() ->
    application:set_env(mcl_sec_guard, proposal_log,
                        "/tmp/opencode/mcl_sec_guard_sup_test.log"),
    {ok, Pid} = mcl_sec_guard_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertMatch([{mcl_sec_guard_recorder, _, worker, _}],
                 supervisor:which_children(Pid)),
    unlink(Pid),
    exit(Pid, shutdown),
    application:unset_env(mcl_sec_guard, proposal_log).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
%%
%% ⚠ TO THE PATCH, AND NOTHING FLOATS. This compared majors only, so when Docker
%% Hub moved the floating `erlang:28-alpine' on 2026-09-22 a service generated
%% from this template shipped OTP 28.5 and its guard stayed green. An image's
%% tag need not name a release, so the builder stage and lint each ASSERT one
%% in a check step; this compares those, .tool-versions and this VM, to the
%% patch.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    Check = "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);",
    Image = pinned("Containerfile", Check),
    CiCheck = pinned(".github/workflows/lint.yml", Check),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    %% Sorted and deduplicated, so a failure prints every version rather than
    %% the first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, CiCheck, Tools, running_otp()])).

%% CI tests in the image that builds, and neither image can move under a tag.
%% The builder stage and lint name ONE image, so a green lint is a statement
%% about the toolchain the release is built with; both FROM lines carry a
%% digest, so a re-pushed tag cannot change what builds or what runs.
ci_builds_in_the_builder_and_both_images_are_digest_pinned_test() ->
    Digest = "@sha256:[0-9a-f]{64}",
    Builder = pinned("Containerfile", "^FROM (\\S+" ++ Digest ++ ") AS builder$"),
    ?assertMatch(<<_/binary>>, pinned("Containerfile", "^FROM (\\S+" ++ Digest ++ ")$")),
    ?assertEqual(Builder, pinned(".github/workflows/lint.yml", "^\\s+image: (\\S+)$")).

%% The full release, 28.4.3 and not 28: `otp_release' names only the major.
running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [multiline, {capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).

%% P0: the one authority actually exercised — a read subscription to the
%% alert topic, nothing else, matching the empty actions/resources above.
listens_to_the_alert_topic_only_test() ->
    ?assertEqual([{<<"denials_observed">>, mcl_sec_guard_subscriber, []}],
                 ?SERVICE:subscriptions()).
