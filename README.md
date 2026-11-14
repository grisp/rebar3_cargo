# `rebar3_cargo`
![CI](https://github.com/rusterlium/rebar3_cargo/workflows/CI/badge.svg)

This plugin for [`rebar3`](https://www.rebar3.org/) enables the automatic
building of Rust crates in an Erlang application.  The plugin will build all
crates in the `crates` directory and copy all binary outputs to
`priv/crates/<cratename>/<binary>`.  See the test application in this repository
for an example of a port program and NIF module implemented in Rust.

## Todo list

As of this writing `rebar3_cargo` will build crates on
linux and passes tests, however it is still under construction.

Todo:
- Appveyor CI
- maybe external crate support using cargo clone


# Using the plugin
Use the plugin by adding the following to `rebar.config`:

``` erlang
{plugins, [
    {rebar3_cargo, {git, "https://github.com/grisp/rebar3_cargo.git", {branch, "cross_build_support_0_1_1"}}}
]}.

{provider_hooks, [
    {pre, [
        {compile, {cargo, build}}
    ]},
    {post, [
        {clean, {cargo, clean}},
        {eunit, {cargo, test}}
    ]}
]}.
```

This fork depends on `https://github.com/grisp/erlang-cargo.git`, branch `cross_build_support_0_1_3`.
No separate application dependency on the Erlang Cargo library is required.
This will automatically download and use `rebar3_cargo`.  Crates will be
compiled whenever the containing app is compiled.  The cargo `--release` switch
will be used when the `prod` profile is active.  For example:

``` sh
rebar3 as prod compile
```

# Application structure with Rust crates
To add crates to an Erlang application, place them in a `crates/` folder, and
reference them in a Cargo Workspace.  All crates found within will be built and
resulting artifacts will be placed in the `priv/crates/` folder.

# Configuration and cross compilation

Cross builds use the same `cargo_opts` configuration as host builds. A rebar
profile can select a target without changing the normal development build:

```erlang
{cargo_opts, [{src_dir, "native"}]}.
{profiles, [{cross, [{cargo_opts, [
    {target, "aarch64-unknown-linux-gnu"},
    {release, true},
    {default_features, false},
    {features, ["portable"]},
    {env, [{"CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER",
            "aarch64-linux-gnu-gcc"}]}
]}]}]}.
```

Run `rebar3 as cross compile` to use that configuration. The Rust target,
linker and any native dependency SDKs must already be installed. Cargo's
`.cargo/config.toml` and target runner settings continue to apply.

The existing options remain available alongside the Cargo options:

| Option | Default | Purpose |
| --- | --- | --- |
| `src_dir` | `"."` | Directory containing Cargo.toml, relative to the application |
| `release` / `debug` | Automatic | Select the Cargo build mode; automatic uses release in the prod profile |
| `skip` | `false` | Skip normal Cargo compilation |
| `load_from_app` | Current application | Application that owns the generated priv/crates files |

Cargo and artifact options:

| Option | Default | Purpose |
| --- | --- | --- |
| `target` | Cargo default | Rust target triple or target specification |
| `target_dir` | Application output `target/` | Cargo cache directory, relative to the application output directory |
| `toolchain` | Active toolchain | Rustup toolchain passed as `cargo +toolchain` |
| `features` | `[]` | Cargo features to enable |
| `default_features` | `true` | Set `false` for `--no-default-features` |
| `library_types` | All library types | Library kinds exposed to external build integrations; ordinary compilation follows the Cargo manifest |
| `env` | `[]` | Environment overrides for child processes; `false` unsets a variable |
| `rustflags` | Cargo default | Argument list passed through `CARGO_ENCODED_RUSTFLAGS` |
| `copy_artifacts` | `true` | Set `false` to leave artifacts in the build directory for an external linker |

Build integrations can use `rebar3_cargo_opts:from_app/2` with command-local
`cargo_overrides` in Rebar state. Overrides take precedence over the
application's options without changing its stored configuration. The normal
build still prepares `cargo.hrl` and the `load_from_app` definition when
compilation is skipped.

# Acknowledgment
This plugin is based on earlier work by
[goertzenator](https://github.com/goertzenator):
[rebar3_rust](https://github.com/goertzenator/rebar3_rust)

## Development

Builds and EUnit work with stable Rust. Common Test uses nightly for fixture
Rust tests because libtest's JSON output is unstable. Ordinary fixture builds
keep the default toolchain. Install nightly once, then run:

```sh
rustup toolchain install nightly
rebar3 eunit
rebar3 ct
```

Set `RUSTUP_TOOLCHAIN` explicitly to test with a pinned nightly version.
