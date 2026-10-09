<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# 🧹 Standalone Linting Action

Runs pre-commit hooks with [prek](https://github.com/j178/prek),
standalone from pre-commit.ci. The primary use case is hooks that
pre-commit.ci cannot run: hooks needing network access at scan time,
or hooks whose environments exceed the pre-commit.ci size limits.

By default (no inputs) the action parses the repository's
`.pre-commit-config.yaml`, takes the hook ids listed under `ci.skip`,
and runs those hooks. When `ci.skip` is empty or absent, the
action succeeds without running anything.

To orchestrate parallel matrix jobs across more than one
configuration, use the `linting.yaml` reusable workflow in
[lfreleng-actions/generic-workflows](https://github.com/lfreleng-actions/generic-workflows),
which builds a lint plan and calls this action for each task. Its
[input reference](https://github.com/lfreleng-actions/generic-workflows/blob/main/docs/linting.md)
covers selection, the JSON plan and the security model. Its
`split_hooks` input (default `true`) divides a selection into one
matrix job per hook, so each hook reports as its own check. Note that
the workflow's default differs from this action's: with no inputs it
runs every hook in the configuration, not the `ci.skip` set.

## Usage Example

An example workflow job using this action:

<!-- markdownlint-disable MD013 -->

```yaml
jobs:
  linting:
    name: 'Standalone linting checks'
    runs-on: 'ubuntu-latest'
    permissions:
      contents: read
    steps:
      # Runs the hooks listed under ci.skip in .pre-commit-config.yaml
      - uses: lfreleng-actions/standalone-linting-action@760ff830dcccde04ca780cd2a7ca36e79ebbd530 # v0.4.1
        with:
          github_token: ${{ github.token }}
```

Run an explicit subset of hooks, space or comma separated. Names may
be a hook's id or its `alias`, and the hooks must run at the
`pre-commit` or `manual` stage, or at `commit-msg`, for hooks such as
`gitlint`, when the caller supplies `commit_range`:

```yaml
      - uses: lfreleng-actions/standalone-linting-action@760ff830dcccde04ca780cd2a7ca36e79ebbd530 # v0.4.1
        with:
          hooks: 'gha-workflow-linter mypy'
```

Run every hook from a remote configuration, with integrity pinning
(naming a configuration implies running it in full):

```yaml
      - uses: lfreleng-actions/standalone-linting-action@760ff830dcccde04ca780cd2a7ca36e79ebbd530 # v0.4.1
        with:
          config_url: 'https://example.org/linting/.pre-commit-config.yaml'
          config_sha256: '<sha256 of the configuration file>'
```

Check every commit message in a pull request with the configuration's
`commit-msg` hooks, such as `gitlint`, as well as linting the files.
`commit_range` is newer than v0.5.0, so pin a release that includes it
rather than the commit shown in these examples:

```yaml
      - uses: lfreleng-actions/standalone-linting-action@760ff830dcccde04ca780cd2a7ca36e79ebbd530 # v0.4.1
        with:
          run_all_hooks: 'true'
          commit_range: '${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}'
```

<!-- markdownlint-enable MD013 -->

## Inputs

<!-- markdownlint-disable MD013 -->

| Variable Name        | Required | Description                                                            | Default        |
| -------------------- | -------- | ---------------------------------------------------------------------- | -------------- |
| hooks                | False    | Space/comma separated hook ids or aliases to run; empty runs ci.skip   |                |
| skip_hooks           | False    | Space/comma separated hook ids or aliases to EXCLUDE from the run      |                |
| run_all_hooks        | False    | Run every hook in the configuration (exclusive with hooks)             | false          |
| per_hook_runs        | False    | Invoke prek once per hook, for one summary row each                    | false          |
| commit_range         | False    | `<from>..<to>`; also run commit-msg hooks on each commit's message     |                |
| config_path          | False    | Configuration path; workspace-relative, or absolute in RUNNER_TEMP     |                |
| config_url           | False    | HTTPS download URL for the configuration (exclusive with config_path)  |                |
| config_sha256        | False    | Expected SHA-256 of the file fetched from config_url                   |                |
| path_prefix          | False    | Directory location containing project code                             | .              |
| branch_name          | False    | Checkout this new Git branch before running linting checks             |                |
| no_checkout          | False    | Don't perform a checkout of the local repository                       | false          |
| github_token         | False    | Token exported as GITHUB_TOKEN/GH_TOKEN to hooks needing API access    |                |
| prek_version         | False    | Version of prek used to run the hooks (X.Y.Z, 0.2.20 or newer)         | 0.4.14         |
| rust_toolchain_setup | False    | Prepare the Rust toolchain for cargo hooks: `auto`, `true` or `false`  | auto           |
| rust_components      | False    | Space/comma separated rustup components added to that toolchain        | rustfmt clippy |
| node_setup           | False    | Prepare a Node.js project for its hooks: `auto`, `true` or `false`     | auto           |
| node_version         | False    | Node.js version; empty reads `.nvmrc`, `.node-version`, `engines.node` |                |
| node_install_scripts | False    | Let the package manager run install scripts                            | false          |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Output Name     | Description                                                                                               |
| --------------- | --------------------------------------------------------------------------------------------------------- |
| config_file     | Resolved path of the linting configuration file                                                           |
| hooks_run       | Space-separated hook names run; 'all' for run_all_hooks; empty on no-op or refusal                        |
| prek_runs       | 'prek run' commands issued: 1 combined, one per hook, plus one per commit checked                         |
| rust_toolchains | Space-separated Rust toolchains the action prepared; empty when it prepared none                          |
| node_version    | Node.js version the hooks run with (`v22.11.0`); empty when Node.js setup did not run or found no Node.js |
| node_prepared   | 'true' when the action prepared the Node.js project, else 'false'                                         |

<!-- markdownlint-enable MD013 -->

## Behaviour

Mode selection:

1. `hooks` set: run the named hook ids
2. `run_all_hooks: 'true'`, or `config_path`/`config_url` supplied:
   run every hook in the configuration
3. Neither (default): run the hooks listed under `ci.skip` in the
   configuration; succeed with a notice when the list is empty

### One invocation, or one per hook

A selection runs in a **single** prek invocation by default. prek
runs hooks concurrently and shares their environments, so a loop pays
a process start and a configuration parse per hook and buys no
isolation — measured on four hooks, 418ms looping against 90ms
combined.

The cost is the job summary, which gets one row for the selection
rather than one per hook, because a single exit status covers them
all. prek's own output still names what failed, so this trades the
table rather than the diagnosis. Set `per_hook_runs: 'true'` to get
the table back.

One behaviour had to be rebuilt for the default. prek reports a
selector matching nothing as an **error** when nothing else matches,
and as a **warning** once another selector does:

```console
$ prek run ... -- no-such-hook
error: No hooks found after filtering        # exit 1

$ prek run ... -- always-passes no-such-hook
warning: selector `no-such-hook` did not match any hooks
Always passes.........................Passed  # exit 0
```

The per-hook loop caught a mistyped hook id for free, one selector at
a time. Collapsing to one invocation would have turned that into a
green check over a smaller set than the caller asked for, so the
action now checks the names itself and fails on one the configuration
does not define. Both modes refuse it.

`skip_hooks` is orthogonal to all three: it EXCLUDES hooks from
whichever set the mode above selected, naming each by id or by
`alias`, and gives the one way to say "run everything except these" —
`hooks` names a subset to include, which cannot express an exclusion.

prek matches selectors against a hook's `alias` as readily as its
`id`, so either name serves in `hooks` as well as in `skip_hooks`.
`hooks_run` echoes back whichever form the caller used.

It applies by two mechanisms, because the two modes resolve the hook
set in different places:

<!-- markdownlint-disable MD013 -->

| Mode                          | Who chooses the set | How exclusions apply               |
| ----------------------------- | ------------------- | ---------------------------------- |
| `run_all_hooks`               | prek                | passed through as `--skip`         |
| `hooks`, or default `ci.skip` | this action         | `prek list --skip` picks survivors |

<!-- markdownlint-enable MD013 -->

Either way prek resolves the matching, so an exclusion naming a hook's
**`alias`** behaves the same in every mode. An earlier version
compared ids inside the action, which left an aliased exclusion
running in the modes that name hooks while `run_all_hooks` excluded
it.

An ambient `SKIP` or `PREK_SKIP` is **merged** with this input rather
than overridden. prek reads those variables in one situation — when no
CLI `--skip` is present — so passing `skip_hooks` alone would suppress
them and run a hook the environment had excluded. `PREK_SKIP` takes
precedence over `SKIP`, matching prek.

A requested hook the configuration does not define is not dropped: it
reaches prek, which refuses it.

Two conditions remove a hook from the reported set. The first is an
exclusion prek confirms it applied. The second is **stage**: a run
reaches `pre-commit` hooks, plus `manual` ones when named and
`commit-msg` ones given a `commit_range`, so the action drops a
hook whose remaining instances sit at `pre-push` or another stage the
run does not enter. prek passes over such a hook without output at
exit 0, and reporting that as a tick would claim a check that never
ran.

Naming such a hook **fails the run**. Where an exclusion leaves a
selected hook with no reachable instance the resolver drops it, but a
hook named directly is a request the action cannot honour, so it says
so rather than reporting a pass:

<!-- markdownlint-disable MD013 -->

```console
::error::requested hooks run at no stage this action reaches: msg-check (commit-msg) ❌
```

<!-- markdownlint-enable MD013 -->

That is the case `gitlint` falls into without `commit_range`, and the
error says so; see [Commit messages](#commit-messages).

The distinction matters for `hooks_run`, which reports what ran
rather than what the caller asked for. Excluding every hook is a
clean no-op in both modes, and a refused selection reports nothing,
because nothing ran. Under `run_all_hooks`, a configuration with no
hook at a stage the run reaches, such as one of `pre-push` hooks
alone, is the same no-op.

Note that prek treats a `--skip` id matching no hook as a no-op, so a
stale entry narrows nothing and the run stays green. Unlike `hooks`,
nothing can catch a typo here: an id absent from the configuration is
indistinguishable from an exclusion whose hook has since gone.

A configuration named on purpose runs in full. Its `ci.skip` describes
what pre-commit.ci skips for the repository that owns it, which says
nothing about a file you pointed the action at; falling to `ci.skip`
mode would run nothing at all for most such files. Pass `hooks` to
narrow it.

Hook ids must match `[A-Za-z0-9][A-Za-z0-9._-]*` — alphanumeric first
character, then alphanumerics, dots, underscores and hyphens. The
action rejects anything else rather than pass it to a shell. The
leading-character rule matters in its own right: an id beginning `-`
would reach the prek command line as an *option*, and `prek run
--help` exits 0, reporting a hook as passed without running it. The
action also terminates option parsing with `--`, so both locks have
to fail before that becomes possible.

Every hook id in practical use fits this, though the rule is narrower
than pre-commit's schema, which types `id` as a free-form string.

Configuration file resolution order:

1. `config_url` (downloaded to the runner temp directory)
2. `config_path`
3. `<path_prefix>/.pre-commit-config.yaml`

A remote configuration never overwrites files in the repository; the
action passes it to prek with `--config`.

### Commit messages

Hooks at the `commit-msg` stage, `gitlint` being the common one, check
a commit message rather than files. A run never reaches them on its
own: prek passes over them without output and exits 0. Set
`commit_range` to run them.

With `commit_range: '<from>..<to>'` the selected hooks **also** run at
the `commit-msg` stage, once per commit in the range, oldest first,
merges included. Each run checks that commit's message, and the job
summary gets one row per commit. One invocation per commit runs every
selected `commit-msg` hook, whatever `per_hook_runs` says: that input
shapes the `pre-commit` stage alone. The selection is the same one the
rest of the run uses, `hooks`, `skip_hooks` and `run_all_hooks` alike;
each hook runs at the stages it declares. A hook declaring no stages
runs at the stages `default_stages` lists, no more, or at every stage
when that key is absent. It runs in both when both appear there, as
it would locally with both hook types installed:
`default_stages: [commit-msg]` gives `commit-msg` alone, and
`default_stages: [pre-commit]`, which this repository's own
configuration sets, gives `pre-commit` alone.

The action takes the range as an input rather than deriving it from
the triggering event, which keeps it predictable, testable, and open
to repositories whose history GitHub does not describe, such as
Gerrit mirrors. Typical values:

<!-- markdownlint-disable MD013 -->

| Event          | `commit_range`                                                                         |
| -------------- | -------------------------------------------------------------------------------------- |
| `pull_request` | `${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}` |
| `push`         | `${{ github.event.before }}..${{ github.event.after }}`                                |
| `merge_group`  | `${{ github.event.merge_group.base_sha }}..${{ github.event.merge_group.head_sha }}`   |

<!-- markdownlint-enable MD013 -->

A `push` that creates a branch reports `before` as all zeros, which
names no commit, so the run refuses it; choose a base for that case,
or skip it.

Every commit in the range must be present. The action's own checkout
fetches full history whenever a caller sets `commit_range`; one
passing `no_checkout: 'true'` must check out with `fetch-depth: 0`
itself. The action refuses, rather than lints in part:

- a range naming a revision the clone does not hold;
- a range in a shallow clone whose ends reach a boundary: the walk
  either stops short without a word or, below a shallow lower end,
  picks up commits outside the range;
- a range selecting no commits, such as a reversed one.

`gitlint` will not start without a git identity, and a CI runner
configures none. Each run sees the identity of the commit's
**author**, through `GIT_CONFIG_COUNT`, scoped to that one process and
written nowhere. Entries the caller already set in `GIT_CONFIG_COUNT`
keep their meaning.

The summary tells "no `commit-msg` hook selected" from "configured
but not run". With a range and no selected `commit-msg` hook, the
action issues a notice that it checked no message. Without a range,
`run_all_hooks` issues one naming each configured hook that the
`commit-msg` stage alone reaches. Naming such a hook in `hooks`
without a range fails the run, as above.

### Rust projects

pre-commit.ci has no cargo to call, so Rust checks belong in local
`language: system` hooks listed under `ci.skip`, which this action
runs by default:

```yaml
ci:
  skip: [cargo-fmt, cargo-clippy]

repos:
  - repo: local
    hooks:
      - id: cargo-fmt
        name: cargo fmt
        entry: cargo fmt --all --check
        language: system
        types: [rust]
        pass_filenames: false
      - id: cargo-clippy
        name: cargo clippy
        entry: cargo clippy --workspace --all-targets -- -D warnings
        language: system
        files: '\.rs$|(^|/)Cargo\.(toml|lock)$'
        pass_filenames: false
```

An optional `cargo-doc` hook follows the same pattern, with
`entry: env RUSTDOCFLAGS=-Dwarnings cargo doc --workspace --no-deps`.

Keep `--workspace` in both. Without it, cargo acts on the root
package of a workspace alone, so a warning in a member crate
would pass unnoticed. `--all-targets` widens the targets checked,
not the packages.

Use `language: system`, not `language: rust`. prek gives a
`language: rust` hook a toolchain of its own: the latest stable, with
the minimal profile, in a rustup home of its own. It ignores the
project's `rust-toolchain.toml`; prek 0.4.14 ran Rust 1.99 for a
project pinning 1.85.

A `language: system` hook calls the rustup proxies, which honour
`rust-toolchain.toml`. On a GitHub-hosted runner they fail for a
project pinning a channel without listing components: the proxy
installs the channel with the minimal profile, and `cargo fmt` then
reports that `cargo-fmt` is not installed for it. So before the hooks
run, the action prepares the toolchain:

- `rust_toolchain_setup: 'auto'` (default) prepares it when
  `path_prefix` holds a tracked `Cargo.toml`; `'true'` prepares it for
  any project, and `'false'` never does
- it asks rustup which toolchain the git top level and `path_prefix`
  select, since prek runs hooks from the top level and a hook may
  change into `path_prefix` first
- it installs a missing toolchain, with the components its toolchain
  file lists, adds `rust_components` to each toolchain, and checks
  that `rustc` runs
- a path-based or linked (`rustup toolchain link`) toolchain gets a
  warning and no preparation; rustup cannot add components to a
  linked one
- without rustup, `'auto'` skips with a notice and `'true'` fails

The action does not read hook entries: in a Rust project it prepares
the toolchain even when none of the selected hooks call cargo. A hook
that changes into some other directory resolves a toolchain the
action did not prepare. The action caches prek's hook environments,
not cargo's registry or `target/`, so cargo hooks build from scratch
on every run.

### Node.js / TypeScript projects

ESLint with a flat config and plugins, Prettier and `tsc` must run
from the project's own `node_modules`, which pre-commit.ci never
installs. So these belong in local `language: system` hooks listed
under `ci.skip`, which this action runs by default. Run them in check
mode: CI should report a problem, not rewrite files and pass.

```yaml
ci:
  skip: [eslint, prettier, tsc]

repos:
  - repo: local
    hooks:
      - id: eslint
        name: eslint
        entry: npx --no-install eslint --max-warnings=0 --no-warn-ignored
        language: system
        types_or: [javascript, jsx, ts, tsx]
      - id: prettier
        name: prettier
        entry: npx --no-install prettier --check --ignore-unknown
        language: system
        types_or: [javascript, jsx, ts, tsx]
      - id: tsc
        name: tsc
        entry: npx --no-install tsc --noEmit
        language: system
        files: '\.(ts|tsx|mts|cts)$|(^|/)tsconfig[^/]*\.json$'
        pass_filenames: false
```

`--no-install` makes `npx` fail rather than fetch whatever release the
registry holds when the project does not depend on the tool. The
[actions-template](https://github.com/lfreleng-actions/actions-template)
`eslint` hook follows the same pattern, adding guards for the ESLint
major version and the config file.

Use `language: system`, not `language: node`. prek installs a
`language: node` hook and its `additional_dependencies` into an
environment of its own. A flat config resolves its `import`s relative
to itself, from the project's `node_modules`, so it cannot see plugins
installed there and fails with `Cannot find package
'typescript-eslint'`. Running the project's own tools also keeps their
versions in one place, `package.json`.

Before the hooks run, the action prepares the project:

- `node_setup: 'auto'` (default) prepares it when `path_prefix` holds
  a `package.json` that git tracks; `'true'` prepares any project, and
  `'false'` never does
- `node_version` selects the Node.js release, through
  `actions/setup-node` with its dependency cache off. Left empty, it
  comes from `.nvmrc`, then `.node-version`, then `engines.node` in
  `package.json` when that is a plain version rather than a range;
  with none, the hooks get the runner's Node.js
- the tracked lockfile chooses the package manager, which installs
  frozen to it, so an out-of-date lockfile fails rather than resolves
  afresh:

<!-- markdownlint-disable MD013 -->

| Lockfile                                   | Install                                                    |
| ------------------------------------------ | ---------------------------------------------------------- |
| `package-lock.json`, `npm-shrinkwrap.json` | `npm ci`                                                   |
| `yarn.lock` (Yarn 1)                       | `yarn install --frozen-lockfile`, through Corepack         |
| `yarn.lock` (Yarn 2+)                      | `yarn install --immutable`, through Corepack               |
| `pnpm-lock.yaml`                           | `pnpm install --frozen-lockfile`, through Corepack         |
| `bun.lock`, `bun.lockb`                    | `bun install --frozen-lockfile`, after `oven-sh/setup-bun` |

<!-- markdownlint-enable MD013 -->

- a `packageManager` field in `package.json` (`pnpm@10.34.6`) chooses
  among tracked lockfiles of different package managers, and sets the
  Yarn, pnpm or Bun release installed. A Yarn 2+ `yarn.lock` needs
  one, since Corepack otherwise runs Yarn 1
- install scripts are off (`--ignore-scripts`; Yarn 2:
  `--skip-builds`; Yarn 3+: `--mode=skip-build`) unless
  `node_install_scripts` is `'true'`
- the install includes devDependencies, where lint tools live, even
  when `NODE_ENV=production`, set for another step, or a `production`
  or `omit=dev` setting in the project's `.npmrc` or `.yarnrc` asks
  otherwise: npm `--include=dev`, Yarn 1 `--production=false`, pnpm
  `--prod=false`. Yarn 2+ always installs them. Bun has no flag to
  override `production = true` in a `bunfig.toml`, so keep that out
  of a Bun project's lint setup
- Node.js 25 and later no longer bundle Corepack. When no `corepack`
  is on `PATH`, the action installs a pinned release with npm
- with a `package.json` but no lockfile to follow, `'auto'` installs
  nothing and warns, so the hooks run without `node_modules`; `'true'`
  fails. `'true'` with no `package.json` selects Node.js alone

Yarn 2+ projects need `nodeLinker: node-modules` in `.yarnrc.yml`:
`npx` cannot find tools under Plug'n'Play.

prek runs every hook from the git top level. When the project sits
in a subdirectory, set `path_prefix` to it and name it in each hook,
since `npx` looks for `node_modules` from the top level and `tsc`
for a `tsconfig.json` there:

```yaml
entry: npx --prefix web --no-install eslint --max-warnings=0 --no-warn-ignored
# ...
entry: npx --prefix web --no-install tsc --noEmit -p web
```

Under `block` egress, Corepack fetches Yarn 2+ from
`repo.yarnpkg.com`, Yarn 1 from `registry.yarnpkg.com` and pnpm from
`registry.npmjs.org`; `oven-sh/setup-bun` downloads Bun from GitHub
releases.

As for Rust, the action does not read hook entries, and it caches
prek's hook environments, not `node_modules`, so every run installs
the dependencies afresh.

## Security

- No secrets required; `github_token` is optional, and reaches no
  further than the hook environment
- All variable data reaches shell steps through `env`, never through
  expression interpolation in `run` blocks
- Hook ids are allow-listed to `[A-Za-z0-9][A-Za-z0-9._-]*`, so a
  configuration cannot smuggle shell metacharacters onto the prek
  command line, nor a leading `-` that prek would read as an option
- The action rejects control characters (notably CR/LF) in every
  string input, which closes the per-line anchoring of `grep -E` and
  keeps `GITHUB_OUTPUT` records single-line
- Each side of `commit_range` is allow-listed to
  `[A-Za-z0-9][A-Za-z0-9._/~^-]*`, then resolved to a commit id behind
  `--end-of-options`; from there on git sees those ids alone
- `path_prefix` stays within the repository workspace, and
  `config_path` within the workspace or `RUNNER_TEMP` (the latter for
  configurations an orchestrating workflow staged); the action
  resolves both with `realpath` and rejects `..` segments and symlink
  escapes
- A remote configuration lands in a private `mktemp` directory, never
  a predictable path a pre-created symlink could redirect into the
  workspace
- `config_url` must be HTTPS; downloads are size- and time-capped and
  support `config_sha256` integrity pinning
- prek installs via `uvx` at an exact pinned version
- Rust preparation turns off rustup's auto-install, installs no
  toolchain beyond the one the project selects, never self-updates
  rustup, and runs nothing from a path-based or linked toolchain.
  Toolchain names must match `[A-Za-z0-9][A-Za-z0-9._+-]*` and
  `rust_components` entries `[A-Za-z0-9][A-Za-z0-9_-]*`, the latter
  passed behind `--`
- Node.js preparation installs what the tracked lockfile pins, and no
  more: frozen, with install scripts off unless `node_install_scripts`
  is `'true'`, and nothing at all without a lockfile. An untracked
  `package.json` or lockfile counts for nothing. `node_version`, and a
  version read from the project, must be a plain version or a
  `setup-node` alias, never a range. `packageManager` must be
  `<npm|yarn|pnpm|bun>@<x.y.z>`. The action restores no dependency
  cache, so nothing a pull request primed can reach a later run

## Breaking changes from v0.2.x

- Hooks run with `prek` instead of `pre-commit`
- The default mode changed from "run all hooks" to "run the hooks
  listed under `ci.skip`"; set `run_all_hooks: 'true'` to restore the
  previous behaviour
- `config_url` downloads to a private directory under `RUNNER_TEMP`
  instead of overwriting `.pre-commit-config.yaml` in the workspace
- The `dependencies_url` input no longer exists; declare hook
  dependencies with `additional_dependencies` in the hook definition
- The `python-version` input no longer exists; prek provisions the
  toolchains (Python via uv, Node.js) that hook environments declare
