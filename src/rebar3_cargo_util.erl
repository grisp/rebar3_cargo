-module(rebar3_cargo_util).

-cargo_header_version(1).

-export([
    get_apps/1,
    get_priv_dir/1,
    cargo_init/3,
    is_cargo_app/1,
    build/1,
    run/1,
    diagnostics/1
]).

-define(DEFAULT_TARGET_DIR, "target").

%% Use raw messages for frontend reporting before selecting build artifacts.
build(Cargo) ->
    Packages = cargo:get_package_versions(Cargo),
    Output = run(fun() -> cargo:build_raw(Cargo, false) end),
    lists:filtermap(
        fun(Entry) ->
            case cargo_artifact:from_json(Entry) of
                {ok, Artifact} ->
                    case maps:find(cargo_artifact:package_id(Artifact), Packages) of
                        {ok, #{version := Version}} ->
                            {true, cargo_artifact:version(Artifact, Version)};
                        error ->
                            false
                    end;
                error ->
                    false
            end
        end,
        Output
    ).

%% Preserve the backend result and original error while reporting through Rebar.
run(Command) ->
    try Command() of
        Output ->
            diagnostics(Output),
            Output
    catch
        error:{cargo_error, {_Code, Output}} = Reason:Stack ->
            diagnostics(Output),
            erlang:raise(error, Reason, Stack)
    end.

diagnostics(Output) ->
    lists:foreach(
        fun
            (#{<<"reason">> := <<"compiler-message">>, <<"message">> := Message}) ->
                Level =
                    case maps:get(<<"level">>, Message) of
                        <<"error">> -> error;
                        <<"warning">> -> warn;
                        _ -> info
                    end,
                Rendered = maps:get(<<"rendered">>, Message, null),
                Text =
                    case Rendered of
                        null -> maps:get(<<"message">>, Message);
                        _ -> Rendered
                    end,
                rebar_log:log(Level, "~ts", [Text]),
                lists:foreach(
                    fun(#{<<"message">> := Child}) ->
                        case binary:match(Text, Child) of
                            nomatch -> rebar_log:log(Level, "~ts", [Child]);
                            _ -> ok
                        end
                    end,
                    maps:get(<<"children">>, Message, [])
                );
            (_) ->
                ok
        end,
        Output
    ).

-spec get_apps(rebar_state:t()) -> [rebar_app_info:t()].
get_apps(State) ->
    Res =
        case rebar_state:current_app(State) of
            undefined ->
                rebar_state:project_apps(State);
            AppInfo ->
                [AppInfo]
        end,
    [App || App <- Res, is_cargo_app(App)].

-spec get_priv_dir(rebar_app_info:t()) -> file:filename_all().
get_priv_dir(App) ->
    %PrivDir = rebar_app_info:priv_dir(App),
    % ensure_dir/1 fails if priv not present
    % (ref https://github.com/erlang/rebar3/issues/1173)
    AppDir = rebar_app_info:dir(App),
    filename:join([AppDir, "priv"]).

-spec cargo_init(
    App :: rebar_app_info:t(),
    CargoOpts :: rebar3_cargo_opts:t(),
    IsRelease :: boolean()
) -> cargo_opts:t().
cargo_init(App, CargoOpts, IsRelease) ->
    Cargo0 = rebar3_cargo_opts:cargo(CargoOpts),
    AppDir = rebar_app_info:dir(App),
    SrcDir = filename:join(AppDir, rebar3_cargo_opts:src_dir(CargoOpts)),
    OutDir = rebar_app_info:out_dir(App),
    RelativeTargetDir =
        case cargo_opts:target_dir(Cargo0) of
            undefined ->
                ?DEFAULT_TARGET_DIR;
            Configured ->
                Configured
        end,
    TargetDir = filename:absname(RelativeTargetDir, OutDir),
    Cargo1 = cargo_opts:path(Cargo0, SrcDir),
    Cargo2 = cargo_opts:target_dir(Cargo1, cargo_util:ensure_binary(TargetDir)),
    cargo_opts:release(Cargo2, IsRelease).

-spec get_src_dir(rebar_app_info:t()) -> filelib:path().
get_src_dir(App) ->
    Opts = rebar3_cargo_opts:from_app(App),
    AppDir = rebar_app_info:dir(App),
    filename:join(AppDir, rebar3_cargo_opts:src_dir(Opts)).

-spec is_cargo_app(rebar_app_info:t()) -> boolean().
is_cargo_app(App) ->
    filelib:is_file(filename:join(get_src_dir(App), "Cargo.toml")).
