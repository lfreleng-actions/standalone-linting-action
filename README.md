<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# ⛔️ Standalone Linting Action

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
which builds a lint plan and calls this action for each task.

## standalone-linting-action

## Usage Example

An example workflow job using this action:

```yaml
jobs:
  linting:
    name: 'Standalone linting checks'
    runs-on: 'ubuntu-latest'
    permissions:
      contents: read
    steps:
      # Runs the hooks listed under ci.skip in .pre-commit-config.yaml
      - uses: lfreleng-actions/standalone-linting-action@main
        with:
          github_token: ${{ github.token }}
```

Run an explicit subset of hooks:

```yaml
      - uses: lfreleng-actions/standalone-linting-action@main
        with:
          hooks: 'mypy gitlint'
```

Run every hook from a remote configuration, with integrity pinning
(naming a configuration implies running it in full):

```yaml
      - uses: lfreleng-actions/standalone-linting-action@main
        with:
          config_url: 'https://example.org/linting/.pre-commit-config.yaml'
          config_sha256: '<sha256 of the configuration file>'
```

## Inputs

<!-- markdownlint-disable MD013 -->

| Variable Name | Required | Description                                                           | Default |
| ------------- | -------- | --------------------------------------------------------------------- | ------- |
| hooks         | False    | Space/comma separated hook ids or aliases to run; empty runs ci.skip  |         |
| skip_hooks    | False    | Space/comma separated hook ids or aliases to EXCLUDE from the run     |         |
| run_all_hooks | False    | Run every hook in the configuration (exclusive with hooks)            | false   |
| config_path   | False    | Configuration path; workspace-relative, or absolute in RUNNER_TEMP    |         |
| config_url    | False    | HTTPS download URL for the configuration (exclusive with config_path) |         |
| config_sha256 | False    | Expected SHA-256 of the file fetched from config_url                  |         |
| path_prefix   | False    | Directory location containing project code                            | .       |
| branch_name   | False    | Checkout this new Git branch before running linting checks            |         |
| no_checkout   | False    | Don't perform a checkout of the local repository                      | false   |
| github_token  | False    | Token exported as GITHUB_TOKEN/GH_TOKEN to hooks needing API access   |         |
| prek_version  | False    | Version of prek used to run the hooks (X.Y.Z, 0.2.20 or newer)        | 0.4.14  |

<!-- markdownlint-enable MD013 -->

## Outputs

<!-- markdownlint-disable MD013 -->

| Output Name | Description                                                             |
| ----------- | ----------------------------------------------------------------------- |
| config_file | Resolved path of the linting configuration file                         |
| hooks_run   | Space-separated hook names run; 'all' for run_all_hooks; empty on no-op |

<!-- markdownlint-enable MD013 -->

## Behaviour

Mode selection:

1. `hooks` set: run the named hook ids
2. `run_all_hooks: 'true'`, or `config_path`/`config_url` supplied:
   run every hook in the configuration
3. Neither (default): run the hooks listed under `ci.skip` in the
   configuration; succeed with a notice when the list is empty

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
reaches `pre-commit` hooks, plus `manual` ones when named, so the
action drops a hook whose remaining instances sit at `pre-push`,
`commit-msg` or another stage a run never enters. prek passes over
such a hook without output at exit 0, and reporting that as a tick
would claim a check that never ran.

The distinction matters for `hooks_run`, which reports what ran
rather than what the caller asked for. Excluding every hook is a
clean no-op in both modes.

Stage pruning applies where the resolver runs, which means where an
exclusion is in play. With no exclusion set, a hook named directly at
an unreached stage still counts as run; issue #156 tracks closing
that gap.

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
