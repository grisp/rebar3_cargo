-module(rebar3_cargo_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
        test_test_nif_app,
        test_test_port_app,
        test_fails_compile,
        test_fails_test,
        test_release_debug,
        test_options_and_overrides,
        test_mixed_apps_and_skip,
        test_configured_build
    ].

test_apps() ->
    [
        "test_nif_app",
        "test_port_app",
        "fails_compile",
        "fails_test",
        "release_debug"
    ].

init_per_suite(Config) ->
    #{priv_dir := PrivDir, data_dir := DataDir} = maps:from_list(Config),

    %% Get plugin source directory
    SrcDir = filename:join(
        lists:takewhile(
            fun
                ("_build") -> false;
                (_) -> true
            end,
            filename:split(DataDir)
        )
    ),

    Rebar = filename:absname(escript:script_name()),
    CargoDir = code:lib_dir(cargo),
    Cargo =
        case file:read_link(filename:join(CargoDir, "src")) of
            {ok, Link} -> filename:dirname(filename:absname(Link, CargoDir));
            {error, einval} -> CargoDir
        end,

    %% For all test apps...
    lists:foreach(
        fun(App) ->
            %% copy from data_dir into priv_dir
            ok = ec_file:copy(
                filename:join(DataDir, App),
                filename:join(PrivDir, App),
                [recursive]
            ),

            RcCheckout = filename:join([PrivDir, App, "_checkouts", "rebar3_cargo"]),
            ok = filelib:ensure_dir(filename:join(RcCheckout, "dummy")),

            lists:foreach(
                fun(Entry) ->
                    ct:pal("Copying from ~s to ~s", [filename:join(SrcDir, Entry), RcCheckout]),
                    ok = ec_file:copy(
                        filename:join(SrcDir, Entry),
                        filename:join(RcCheckout, Entry),
                        [recursive]
                    )
                end,
                ["rebar.config", "src"]
            ),

            %% Run fixtures with this Rebar and the actual backend under test.
            CargoCheckout = filename:join([PrivDir, App, "_checkouts", "cargo"]),
            ok = filelib:ensure_dir(filename:join(CargoCheckout, "dummy")),
            lists:foreach(
                fun(Entry) ->
                    ok = ec_file:copy(
                        filename:join(Cargo, Entry),
                        filename:join(CargoCheckout, Entry),
                        [recursive]
                    )
                end,
                ["rebar.config", "src"]
            ),
            ok = ec_file:copy(
                Rebar,
                filename:join([PrivDir, App, "rebar3"])
            )
        end,
        test_apps()
    ),

    Config.

end_per_suite(Config) ->
    Config.

%% libtest JSON is nightly-only; ordinary fixture builds keep the caller's toolchain.
%% Honor an explicit toolchain so pinned nightly versions can be tested too.
rust_test_opts(AppDir) ->
    rust_test_opts(AppDir, []).

rust_test_opts(AppDir, Env) ->
    Toolchain =
        case os:getenv("RUSTUP_TOOLCHAIN") of
            false -> "nightly";
            Selected -> Selected
        end,
    [{cd, AppDir}, {use_stdout, true}, {env, [{"RUSTUP_TOOLCHAIN", Toolchain} | Env]}].

test_options_and_overrides(Config) ->
    Root = filename:join(?config(priv_dir, Config), "options"),
    {ok, App0} = rebar_app_info:new(<<"options">>, "0.1.0", Root),
    Base = [
        {src_dir, "native"},
        {debug, true},
        {target, "base-target"},
        {features, ["base"]},
        {rustflags, ["-C", "opt-level=1"]}
    ],
    App = rebar_app_info:opts(App0, dict:from_list([{cargo_opts, Base}])),
    State = rebar_state:set(
        rebar_state:new(),
        cargo_overrides,
        [
            {target, "override-target"},
            {target_dir, "shared target"},
            {default_features, false}
        ]
    ),
    Options = rebar3_cargo_opts:from_app(App, State),
    ?assertEqual(debug, rebar3_cargo_opts:mode(Options)),
    Cargo = rebar3_cargo_util:cargo_init(App, Options, false),
    ?assertEqual(<<"override-target">>, cargo_opts:target(Cargo)),
    ?assertEqual([<<"base">>], cargo_opts:features(Cargo)),
    ?assertEqual([<<"-C">>, <<"opt-level=1">>], cargo_opts:rustflags(Cargo)),
    ?assertEqual(false, cargo_opts:default_features(Cargo)),
    ?assertEqual(filename:join(Root, "native"), cargo_opts:path(Cargo)),
    ?assertEqual(
        list_to_binary(filename:join(Root, "shared target")), cargo_opts:target_dir(Cargo)
    ),
    Original = rebar3_cargo_opts:from_app(App),
    ?assertEqual(<<"base-target">>, cargo_opts:target(rebar3_cargo_opts:cargo(Original))),
    Absolute = filename:join(?config(priv_dir, Config), "absolute target"),
    AbsoluteState = rebar_state:set(State, cargo_overrides, [{target_dir, Absolute}]),
    AbsoluteCargo = rebar3_cargo_util:cargo_init(
        App,
        rebar3_cargo_opts:from_app(App, AbsoluteState),
        true
    ),
    ?assertEqual(list_to_binary(Absolute), cargo_opts:target_dir(AbsoluteCargo)).

test_mixed_apps_and_skip(Config) ->
    Root = filename:join(?config(priv_dir, Config), "mixed"),
    Manifest = filename:join(Root, "Cargo.toml"),
    ok = filelib:ensure_dir(Manifest),
    ok = file:write_file(Manifest, <<"[package]\nname='mixed'\nversion='0.1.0'\n">>),
    {ok, App} = rebar_app_info:new(<<"mixed">>, "0.1.0", Root),
    {ok, Plain} = rebar_app_info:new(<<"plain">>, "0.1.0", filename:join(Root, "plain")),
    State0 = rebar_state:project_apps(rebar_state:new(), [Plain, App]),
    State = rebar_state:set(State0, cargo_overrides, [{skip, true}, {load_from_app, plain}]),
    ?assertEqual([App], rebar3_cargo_util:get_apps(State)),
    {ok, Prepared} = rebar3_cargo_compile_prv:do(State),
    [Plain, Once] = rebar_state:project_apps(Prepared),
    ?assert(filelib:is_file(filename:join([Root, "src", "cargo.hrl"]))),
    Twice = rebar3_cargo_compile:compile_app(Once, State),
    ?assertEqual(
        [{d, 'CARGO_LOAD_APP', plain}], rebar_opts:get(rebar_app_info:opts(Twice), erl_opts, [])
    ),
    ?assertEqual(false, rebar3_cargo_opts:skip(rebar3_cargo_opts:from_app(App))).

test_configured_build(Config) ->
    Root = filename:join(?config(priv_dir, Config), "configured"),
    Manifest = filename:join([Root, "native", "Cargo.toml"]),
    Source = filename:join([Root, "native", "src", "lib.rs"]),
    ok = filelib:ensure_dir(Source),
    ok = file:write_file(
        Manifest,
        <<
            "[package]\nname='configured'\nversion='0.1.0'\nedition='2018'\n"
            "[lib]\ncrate-type=['staticlib']\n[features]\n"
            "default=['unwanted']\nunwanted=[]\nselected=[]\n"
        >>
    ),
    ok = file:write_file(
        Source,
        <<
            "#[cfg(feature=\"unwanted\")] compile_error!(\"default feature enabled\");\n"
            "#[cfg(not(feature=\"selected\"))] compile_error!(\"selected feature missing\");\n"
            "#[cfg(not(configured))] compile_error!(\"rustflags missing\");\n"
            "pub fn value()-> &'static str { env!(\"CARGO_PLUGIN_VALUE\") }\n"
        >>
    ),
    {ok, App0} = rebar_app_info:new(<<"configured">>, "0.1.0", Root),
    App = rebar_app_info:opts(
        App0,
        dict:from_list([
            {cargo_opts, [
                {src_dir, "native"},
                {copy_artifacts, false},
                {default_features, false},
                {features, ["selected"]},
                {rustflags, ["--cfg", "configured"]},
                {target_dir, "custom target"},
                {env, [{"CARGO_PLUGIN_VALUE", "present"}]}
            ]}
        ])
    ),
    State = rebar_state:project_apps(rebar_state:new(), [App]),
    _ = rebar3_cargo_compile:compile_app(App, State),
    ?assertNot(filelib:is_dir(filename:join([Root, "priv", "crates"]))),
    Options = rebar3_cargo_opts:from_app(App, State),
    Cargo = rebar3_cargo_util:cargo_init(App, Options, false),
    [Artifact] = rebar3_cargo_util:build(Cargo),
    ?assertEqual(staticlib, cargo_artifact:kind(Artifact)),
    ?assertEqual(<<"0.1.0">>, cargo_artifact:version(Artifact)),
    ?assert(filelib:is_dir(binary_to_list(cargo_opts:target_dir(Cargo)))),
    Marker = filename:join([Root, "priv", "crates", "keep"]),
    ok = filelib:ensure_dir(Marker),
    ok = file:write_file(Marker, <<"external artifact">>),
    {ok, _} = rebar3_cargo_clean_prv:do(State),
    ?assert(filelib:is_file(Marker)).

%% The main test application.  Tests Rust port and nif.
test_test_nif_app(Config) ->
    #{priv_dir := PrivDir} = maps:from_list(Config),
    AppDir = filename:join(PrivDir, "test_nif_app"),

    %% check for Rust build artifact
    {ok, _} = rebar_utils:sh("escript rebar3 as prod compile", [{cd, AppDir}, {use_stdout, true}]),
    {ok, _} = rebar_utils:sh("escript rebar3 as prod clean", [{cd, AppDir}, {use_stdout, true}]),
    {ok, _} = rebar_utils:sh("escript rebar3 eunit", rust_test_opts(AppDir)),
    {ok, _} = rebar_utils:sh("escript rebar3 clean", [{cd, AppDir}, {use_stdout, true}]),

    ok.

test_test_port_app(Config) ->
    #{priv_dir := PrivDir} = maps:from_list(Config),
    AppDir = filename:join(PrivDir, "test_port_app"),

    ErlCommName = filename:join(
        [
            AppDir,
            "priv",
            "crates",
            "erl_comm",
            "erl_comm" ++
                case os:type() of
                    {win32, _} -> ".exe";
                    _ -> ""
                end
        ]
    ),

    %% check for Rust build artifact
    false = filelib:is_file(ErlCommName),
    {ok, _} = rebar_utils:sh("escript rebar3 as prod compile", [{cd, AppDir}, {use_stdout, true}]),
    true = filelib:is_file(ErlCommName),
    {ok, _} = rebar_utils:sh("escript rebar3 as prod clean", [{cd, AppDir}, {use_stdout, true}]),
    false = filelib:is_file(ErlCommName),
    {ok, _} = rebar_utils:sh("escript rebar3 eunit", rust_test_opts(AppDir)),
    {ok, _} = rebar_utils:sh("escript rebar3 clean", [{cd, AppDir}, {use_stdout, true}]),
    false = filelib:is_file(ErlCommName),

    ok.

%% test that rust compile failure causes rebar3 compile failure.
test_fails_compile(Config) ->
    #{priv_dir := PrivDir} = maps:from_list(Config),
    AppDir = filename:join(PrivDir, "fails_compile"),
    {error, {_, Output}} = rebar_utils:sh("escript rebar3 compile", [
        {cd, AppDir},
        {use_stdout, true},
        return_on_error
    ]),
    ?assertNotEqual(nomatch, string:find(Output, "rust_src/uhoh/src/main.rs:2:")),
    ok.

%% test that rust test failure causes rebar3 test failure.
test_fails_test(Config) ->
    #{priv_dir := PrivDir} = maps:from_list(Config),
    AppDir = filename:join(PrivDir, "fails_test"),
    {error, {_, Output}} = rebar_utils:sh(
        "escript rebar3 eunit",
        [return_on_error | rust_test_opts(AppDir, [{"DIAGNOSTIC", "1"}])]
    ),
    ?assertNotEqual(nomatch, string:find(Output, "deliberate Rust fixture test failure")),
    ?assertNotEqual(nomatch, string:find(Output, "test failed, to rerun pass `--bin uhoh2`")),
    ok.

%% check debug vs release builds
test_release_debug(Config) ->
    #{priv_dir := PrivDir} = maps:from_list(Config),
    AppDir = filename:join(PrivDir, "release_debug"),
    Prefix = filename:join([AppDir, "priv", "crates", "build_type"]),
    DebugExeName = filename:join([
        Prefix,
        "build_type" ++
            case os:type() of
                {win32, _} -> ".exe";
                {unix, _} -> ""
            end
    ]),
    {ok, _} = rebar_utils:sh("escript rebar3 compile", [{cd, AppDir}, {use_stdout, true}]),
    {ok, "debug"} = rebar_utils:sh(DebugExeName, [{cd, AppDir}, {use_stdout, true}]),

    ReleaseExeName = filename:join([
        Prefix,
        "build_type" ++
            case os:type() of
                {win32, _} -> ".exe";
                {unix, _} -> ""
            end
    ]),
    {ok, _} = rebar_utils:sh("escript rebar3 as prod compile", [{cd, AppDir}, {use_stdout, true}]),
    {ok, "release"} = rebar_utils:sh(ReleaseExeName, [{cd, AppDir}, {use_stdout, true}]),

    ok.
