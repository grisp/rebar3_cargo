-module(rebar3_cargo_compile).

-export([
    force_compile_app/2,
    compile_app/2
]).

-spec force_compile_app(rebar_app_info:t(), rebar_state:t()) -> rebar_app_info:t().
force_compile_app(App, State) ->
    CargoOpts = rebar3_cargo_opts:from_app(App, State),
    rebar3_cargo_header:ensure(App),

    TargetApp = get_target_app(CargoOpts, App, State),
    do_compile_app(CargoOpts, App, TargetApp, State),
    patch_app(App, TargetApp).

-spec compile_app(rebar_app_info:t(), rebar_state:t()) -> rebar_app_info:t().
compile_app(App, State) ->
    CargoOpts = rebar3_cargo_opts:from_app(App, State),
    rebar3_cargo_header:ensure(App),

    TargetApp = get_target_app(CargoOpts, App, State),

    case rebar3_cargo_opts:skip(CargoOpts) of
        true ->
            rebar_log:log(info, "Skipping cargo build of ~s", [rebar_app_info:name(App)]);
        _ ->
            do_compile_app(CargoOpts, App, TargetApp, State)
    end,

    patch_app(App, TargetApp).

do_compile_app(CargoOpts, App, TargetApp, State) ->
    IsRelease =
        case rebar3_cargo_opts:mode(CargoOpts) of
            release ->
                true;
            debug ->
                false;
            auto ->
                lists:member(prod, rebar_state:current_profiles(State))
        end,

    Cargo = rebar3_cargo_util:cargo_init(App, CargoOpts, IsRelease),
    Artifacts = rebar3_cargo_util:build(Cargo),

    case rebar3_cargo_opts:copy_artifacts(CargoOpts) of
        true ->
            Target = cargo_opts:target(Cargo),
            lists:foreach(
                fun(Artifact) ->
                    do_crate(Artifact, IsRelease, TargetApp, Target)
                end,
                Artifacts
            );
        false ->
            ok
    end.

patch_app(App, TargetApp) ->
    AppName = binary_to_atom(rebar_app_info:name(TargetApp), utf8),
    ErlOpts = [{d, 'CARGO_LOAD_APP', AppName}],

    Opts = rebar_app_info:opts(App),

    Existing = rebar_opts:get(Opts, erl_opts, []),
    ErlOpts1 = ErlOpts ++ lists:filter(fun filter_load_app/1, Existing),
    Opts1 = rebar_opts:set(Opts, erl_opts, ErlOpts1),

    rebar_app_info:opts(App, Opts1).

get_target_app(CargoOpts, App, State) ->
    case rebar3_cargo_opts:load_from_app(CargoOpts) of
        undefined ->
            App;
        Other ->
            [OtherApp | _] = [
                A
             || A <- rebar_state:project_apps(State),
                rebar_app_info:name(A) =:= atom_to_binary(Other, utf8)
            ],
            OtherApp
    end.

%% Repeated target/host builds must not accumulate conflicting preprocessor defines.
filter_load_app({d, 'CARGO_LOAD_APP', _}) ->
    false;
filter_load_app(_) ->
    true.

%% Use the target and artifact format for cross builds, including custom targets.
%% An unspecified target keeps the host behavior, including executable names.
target_os(undefined, _Extension) ->
    os:type();
target_os(Target, Extension) ->
    case {Extension, binary:match(Target, <<"windows">>)} of
        {<<".dll">>, _} ->
            {win32, nt};
        {<<".exe">>, _} ->
            {win32, nt};
        {<<".dylib">>, _} ->
            {unix, darwin};
        {_, {_, _}} ->
            {win32, nt};
        _ ->
            {unix, linux}
    end.

do_crate(Artifact, IsRelease, App, Target) ->
    Name = cargo_artifact:name(Artifact),
    _Version = cargo_artifact:version(Artifact),
    Files = cargo_artifact:filenames(Artifact),

    _Type =
        case IsRelease of
            true ->
                "release";
            false ->
                "debug"
        end,

    PrivDir = rebar3_cargo_util:get_priv_dir(App),
    OutDir = filename:join([PrivDir, "crates", Name]),

    filelib:ensure_dir(filename:join([OutDir, "dummy"])),

    % TODO: Distinguish nif vs. other cases here?
    lists:foreach(
        fun(F) ->
            case filelib:is_regular(F) of
                true ->
                    cp(F, OutDir, target_os(Target, filename:extension(F)));
                _ ->
                    false
            end
        end,
        Files
    ),

    ok.

-spec cp(file:filename_all(), file:name_all(), {unix | win32, atom()}) -> ok | {error, ignored}.
cp(Src, DstDir, OsType) ->
    Extension = filename:extension(Src),
    Fname = filename:basename(Src, Extension),

    % Erlang's load_nif/2 is not prepared to read Mac OS's .dylib extension,
    % take a shortcut here and rename the extension to .so in that case
    Dst0 = maybe_rename_extension(OsType, Fname, Extension),
    Dst1 = maybe_strip_lib(OsType, Dst0),

    OutPath = filename:join([DstDir, Dst1]),

    rebar_api:info("  Copying ~s to ~s...", [Fname, OutPath]),

    file:delete(OutPath),

    case file:copy(Src, OutPath) of
        {ok, _} ->
            % Preserve file info
            {ok, SrcFileInfo} = file:read_file_info(Src),
            ok = file:write_file_info(OutPath, SrcFileInfo),
            ok;
        Error ->
            rebar_api:warn("  Failed to copy ~s: ~p", [Fname, Error])
    end,
    ok.

-spec maybe_rename_extension(
    OsType :: {unix | win32, atom()},
    Name :: file:filename_all(),
    Extension :: file:filename_all()
) -> file:filename_all().
maybe_rename_extension({unix, darwin}, Name, <<".dylib">>) ->
    filename:flatten([Name, ".so"]);
maybe_rename_extension(_, Name, Extension) ->
    filename:flatten([Name, Extension]).

maybe_strip_lib({win32, _}, Name) ->
    Name;
maybe_strip_lib(_, Name) ->
    case string:prefix(filename:flatten(Name), "lib") of
        nomatch ->
            filename:flatten(Name);
        Else ->
            Else
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

artifact_names_test() ->
    Cases = [
        {{unix, linux}, <<"libnif">>, <<".so">>, "nif.so"},
        {{unix, darwin}, <<"libnif">>, <<".dylib">>, "nif.so"},
        {{win32, nt}, <<"nif">>, <<".dll">>, "nif.dll"},
        {{win32, nt}, <<"port">>, <<".exe">>, "port.exe"},
        {{win32, nt}, <<"libport">>, <<".exe">>, "libport.exe"},
        {{unix, linux}, <<"libhelper">>, <<".rlib">>, "helper.rlib"},
        {{unix, linux}, <<"libnif">>, <<".a">>, "nif.a"}
    ],
    lists:foreach(
        fun({Os, Name, Ext, Expected}) ->
            Actual = maybe_strip_lib(Os, maybe_rename_extension(Os, Name, Ext)),
            ?assertEqual(list_to_binary(Expected), iolist_to_binary(Actual))
        end,
        Cases
    ),
    ?assertEqual(os:type(), target_os(undefined, <<".so">>)),
    ?assertEqual({win32, nt}, target_os(<<"x86_64-pc-windows-msvc">>, <<".dll">>)),
    ?assertEqual({unix, darwin}, target_os(<<"aarch64-apple-darwin">>, <<".dylib">>)),
    ?assertEqual({unix, linux}, target_os(<<"armv7a-none-eabihf">>, <<".a">>)),
    ?assertEqual({unix, darwin}, target_os(<<"custom-target.json">>, <<".dylib">>)),
    ?assertEqual({win32, nt}, target_os(<<"custom-target.json">>, <<".dll">>)).

load_app_define_test() ->
    {ok, App0} = rebar_app_info:new(<<"owner">>, "1", "/tmp/owner"),
    App = rebar_app_info:opts(
        App0,
        dict:from_list([
            {erl_opts, [debug_info, {d, 'KEEP', true}, {d, 'CARGO_LOAD_APP', previous}]}
        ])
    ),
    {ok, Target} = rebar_app_info:new(<<"load_owner">>, "1", "/tmp/load_owner"),
    Once = patch_app(App, Target),
    Twice = patch_app(Once, Target),
    ?assertEqual(
        [{d, 'CARGO_LOAD_APP', load_owner}, debug_info, {d, 'KEEP', true}],
        rebar_opts:get(rebar_app_info:opts(Twice), erl_opts, [])
    ).
-endif.
