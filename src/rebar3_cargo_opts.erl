-module(rebar3_cargo_opts).

-export([
    from_app/1,
    from_app/2,
    from_state/1
]).

-export([
    mode/1,
    skip/1,
    load_from_app/1,
    src_dir/1,
    cargo/1,
    copy_artifacts/1
]).

-export_type([
    t/0
]).

-define(DEFAULT_SRC_DIR, ".").
-define(KEY, cargo_opts).

-type mode() :: release | debug | auto.

-record(opts, {
    mode :: mode(),
    skip :: boolean(),
    load_from_app :: atom(),
    src_dir :: filelib:file_path(),
    cargo :: cargo_opts:t(),
    copy_artifacts :: boolean()
}).

-opaque t() :: #opts{}.

-spec from_app(rebar_app_info:t()) -> t().
from_app(App) ->
    AppOpts = rebar_app_info:opts(App),
    Opts =
        case dict:find(?KEY, AppOpts) of
            {ok, O} ->
                O;
            _ ->
                []
        end,

    from_opts(Opts).

%% Overrides apply to this command without mutating application configuration.
-spec from_app(rebar_app_info:t(), rebar_state:t()) -> t().
from_app(App, State) ->
    Base = rebar_opts:get(rebar_app_info:opts(App), cargo_opts, []),
    Overrides = rebar_state:get(State, cargo_overrides, []),
    from_opts(Overrides ++ Base).

-spec from_state(rebar_state:t()) -> t().
from_state(State) ->
    CargoOpts = rebar_state:get(State, cargo_opts, []),
    from_opts(CargoOpts).

from_opts(Opts) ->
    Release = proplists:get_value(release, Opts),
    Debug = proplists:get_value(debug, Opts),

    Mode =
        case {Release, Debug} of
            {true, _} ->
                release;
            {_, true} ->
                debug;
            _ ->
                auto
        end,

    #opts{
        mode = Mode,
        skip = proplists:get_bool(skip, Opts),
        load_from_app = proplists:get_value(load_from_app, Opts),
        src_dir = proplists:get_value(src_dir, Opts, ?DEFAULT_SRC_DIR),
        cargo = cargo_opts:new(backend_options(Opts)),
        copy_artifacts = proplists:get_value(copy_artifacts, Opts, true)
    }.

-spec mode(t()) -> mode().
mode(#opts{mode = Mode}) -> Mode.

-spec skip(t()) -> boolean().
skip(#opts{skip = Skip}) -> Skip.

-spec load_from_app(t()) -> atom().
load_from_app(#opts{load_from_app = App}) -> App.

-spec src_dir(t()) -> string().
src_dir(#opts{src_dir = SrcDir}) -> SrcDir.

-spec cargo(t()) -> cargo_opts:t().
cargo(#opts{cargo = Cargo}) -> Cargo.

-spec copy_artifacts(t()) -> boolean().
copy_artifacts(#opts{copy_artifacts = Copy}) -> Copy.

backend_options(Opts) ->
    Defaults = cargo_opts:new(#{path => "."}),
    #{
        path => ".",
        target => optional_binary(proplists:get_value(target, Opts, cargo_opts:target(Defaults))),
        target_dir => optional_binary(
            proplists:get_value(target_dir, Opts, cargo_opts:target_dir(Defaults))
        ),
        toolchain => optional_binary(
            proplists:get_value(toolchain, Opts, cargo_opts:toolchain(Defaults))
        ),
        features => binary_list(proplists:get_value(features, Opts, cargo_opts:features(Defaults))),
        default_features => proplists:get_value(
            default_features, Opts, cargo_opts:default_features(Defaults)
        ),
        library_types => binary_list(
            proplists:get_value(library_types, Opts, cargo_opts:library_types(Defaults))
        ),
        env => proplists:get_value(env, Opts, cargo_opts:env(Defaults)),
        rustflags => binary_list(
            proplists:get_value(rustflags, Opts, cargo_opts:rustflags(Defaults))
        )
    }.

optional_binary(undefined) ->
    undefined;
optional_binary(Value) ->
    cargo_util:ensure_binary(Value).

binary_list(undefined) ->
    undefined;
binary_list(Values) ->
    [cargo_util:ensure_binary(V) || V <- Values].
