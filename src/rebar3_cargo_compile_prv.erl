-module(rebar3_cargo_compile_prv).

-export([
    init/1,
    do/1,
    format_error/1
]).

-include("internal.hrl").

-define(PROVIDER, build).
-define(DEPS, [{default, app_discovery}]).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
        % The 'user friendly' name of the task
        {name, ?PROVIDER},
        {namespace, ?NAMESPACE},
        % The module implementation of the task
        {module, ?MODULE},
        % The task can be run by the user, always true
        {bare, true},
        % The list of dependencies
        {deps, ?DEPS},
        % How to use the plugin
        {example, "rebar3 cargo build"},
        % list of options understood by the plugin
        {opts, []},
        {short_desc, "Compile Rust crates"},
        {desc, "Compile Rust crates"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    try do_build(State)
    catch
        error:{cargo_not_found, Cargo} ->
            rebar_api:abort(
                "Cargo executable '~s' was not found in PATH. " ++
                "The Cargo build hook runs on this host; install Rust/Cargo " ++
                "and check 'cargo --version' in this terminal.", [Cargo])
    end.

do_build(State) ->
    %% execute for each app
    State1 =
        case rebar_state:current_app(State) of
            undefined ->
                rebar_api:info("No current app, using project apps", []),
                NewApps = [
                    compile_app(App, State)
                 || App <- rebar_state:project_apps(State)
                ],
                rebar_state:project_apps(State, NewApps);
            AppInfo ->
                rebar_state:current_app(State, compile_app(AppInfo, State))
        end,

    {ok, State1}.

compile_app(App, State) ->
    case rebar3_cargo_util:is_cargo_app(App) of
        true ->
            rebar3_cargo_compile:compile_app(App, State);
        false ->
            App
    end.
