#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the 'Validate inputs' step in action.yaml.
#
# The rejection cases in .github/workflows/testing.yaml can assert
# only that the action FAILED. A composite action exposes no inner
# step outcomes, so its caller cannot tell 'validation refused this'
# from 'something later fell over'. A case whose input also breaks a
# later step therefore keeps passing after the guard it targets is
# deleted (standalone-linting-action#171).
#
# This suite runs the validate step ON ITS OWN and asserts the refusal
# it prints, so deleting a guard fails here even where the action
# would still fail further on. It covers every rejection case that
# testing.yaml sends to this step.
#
# The step is EXTRACTED from action.yaml by tests/lib/action-step.sh,
# never copied, so these fixtures exercise the code the action runs.
# Every input starts at its declared default, and a case layers
# VAR=VALUE pairs over that.
#
# Usage: tests/test-validate-inputs.sh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
action="${repo_root}/action.yaml"

# shellcheck source=tests/lib/action-step.sh
. "${script_dir}/lib/action-step.sh"

if [ ! -f "${action}" ]; then
    echo "ERROR: action not found: ${action}" >&2
    exit 1
fi

action_step_python

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
step="${workdir}/validate.sh"
defaults="${workdir}/defaults"
runner_temp="${workdir}/runner-temp"
mkdir "${runner_temp}"

action_step_extract "${action}" validate "${step}" "${defaults}"

base_env=()
known=' '
while IFS= read -r -d '' entry; do
    base_env+=("${entry}")
    known="${known}${entry%%=*} "
done < "${defaults}"

if [ ! -s "${step}" ] || [ "${#base_env[@]}" -eq 0 ]; then
    echo "ERROR: the 'validate' step in ${action}" >&2
    echo '       has no script, or reads no inputs.' >&2
    exit 1
fi

# The step resolves paths with 'realpath -e', which is GNU. macOS
# ships a BSD realpath without it; Homebrew's coreutils installs the
# GNU one as 'grealpath'.
if ! realpath -e / > /dev/null 2>&1; then
    if ! command -v grealpath > /dev/null 2>&1; then
        echo "ERROR: the validate step needs GNU 'realpath -e'" >&2
        echo '       On macOS: brew install coreutils' >&2
        exit 1
    fi
    mkdir "${workdir}/bin"
    ln -s "$(command -v grealpath)" "${workdir}/bin/realpath"
    PATH="${workdir}/bin:${PATH}"
fi

passed=0
failed=0
status=0

# Run the step as the runner does: from the workspace root, under
# 'bash --noprofile --norc -eo pipefail', in a clean environment.
# Every input starts at its default and the arguments, VAR=VALUE
# pairs, override them. Sets 'status'; the output lands in
# ${workdir}/out.
run_step() {
    local pair
    for pair in "$@"; do
        case "${known}" in
            *" ${pair%%=*} "*) ;;
            *)
                echo "ERROR: the step does not read ${pair%%=*}" >&2
                exit 1
                ;;
        esac
    done
    status=0
    (
        cd "${repo_root}"
        env -i PATH="${PATH}" \
            GITHUB_WORKSPACE="${repo_root}" \
            RUNNER_TEMP="${runner_temp}" \
            "${base_env[@]}" "$@" \
            bash --noprofile --norc -eo pipefail "${step}"
    ) > "${workdir}/out" 2>&1 || status=$?
}

pass() {
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    failed=$((failed + 1))
    printf 'FAIL: %s\n      expected %s; exit status %s, output:\n' \
        "$1" "$2" "${status}"
    sed 's/^/        /' "${workdir}/out"
}

# $1 describes the case, the rest are VAR=VALUE pairs.
accept() {
    local desc="$1"
    shift
    run_step "$@"
    if [ "${status}" -eq 0 ] &&
        ! grep -q '^::error::' "${workdir}/out"; then
        pass "${desc}"
    else
        fail "${desc}" 'acceptance'
    fi
}

# $1 describes the case and $2 is the refusal its guard prints, minus
# the '::error::' prefix and the trailing mark. The rest are VAR=VALUE
# pairs. Matched as a whole line, so another check refusing the same
# input does not stand in for the guard under test.
reject() {
    local desc="$1" expected="$2" line found=0
    shift 2
    run_step "$@"
    while IFS= read -r line; do
        case "${line}" in
            "::error::${expected} ❌") found=1 ;;
        esac
    done < "${workdir}/out"
    if [ "${status}" -eq 1 ] && [ "${found}" -eq 1 ]; then
        pass "${desc}"
    else
        fail "${desc}" "refusal '${expected}'"
    fi
}

config_url='https://raw.githubusercontent.com/lfreleng-actions/'
config_url="${config_url}test-python-project/refs/heads/main/"
config_url="${config_url}resources/pre-commit-config.yaml"
zero_digest="$(printf '%064d' 0)"

# --- Accepted ----------------------------------------------------------

# A guard refusing EVERYTHING would satisfy every rejection below, so
# well-formed values for the same inputs must still pass.

accept 'the action defaults'

accept 'prek_version at the floor' INPUT_PREK_VERSION='0.2.20'

accept 'a pinned https config_url' \
    INPUT_CONFIG_URL="${config_url}" \
    INPUT_CONFIG_SHA256="${zero_digest}"

accept 'hook ids in hooks and skip_hooks' \
    INPUT_HOOKS='check-yaml, end-of-file-fixer' \
    INPUT_SKIP_HOOKS='aislop'

accept 'a workspace config_path with per_hook_runs' \
    INPUT_CONFIG_PATH='.pre-commit-config.yaml' \
    INPUT_HOOKS='check-yaml' \
    INPUT_PER_HOOK_RUNS='true'

accept 'a commit_range of names and suffixes' \
    INPUT_COMMIT_RANGE='origin/main..HEAD~1'

accept 'a commit_range of commit ids' \
    INPUT_COMMIT_RANGE="${zero_digest:0:40}..${zero_digest:0:40}"

accept 'rust_toolchain_setup forced on, components comma separated' \
    INPUT_RUST_TOOLCHAIN_SETUP='true' \
    INPUT_RUST_COMPONENTS='rustfmt,clippy, llvm-tools'

accept 'rust_toolchain_setup off, no components' \
    INPUT_RUST_TOOLCHAIN_SETUP='false' INPUT_RUST_COMPONENTS=''

accept 'a rust_components entry of 64 characters' \
    INPUT_RUST_COMPONENTS="r$(printf '%063d' 0)"

accept 'node_setup forced on, scripts on, a full version' \
    INPUT_NODE_SETUP='true' INPUT_NODE_INSTALL_SCRIPTS='true' \
    INPUT_NODE_VERSION='v22.11.0'

accept 'node_setup off' INPUT_NODE_SETUP='false'

for node_version in 22 22.11 22.x 22.11.x lts/'*' lts/iron node latest \
    current; do
    accept "node_version '${node_version}'" \
        INPUT_NODE_VERSION="${node_version}"
done

# --- Refused -----------------------------------------------------------

# One per rejection case in testing.yaml that this step refuses, with
# the same input.

reject 'config_path traversal' \
    "config_path must not contain '..'" \
    INPUT_CONFIG_PATH='../.pre-commit-config.yaml'

reject 'plaintext http config_url' \
    'config_url must be an https:// URL' \
    INPUT_CONFIG_URL='http://example.org/config.yaml'

reject 'hook id that is a prek option' \
    'invalid hook id: --help' \
    INPUT_HOOKS='--help'

# Run from the repository root, so an unquoted expansion would turn
# '*' into file names that pass the id check.
reject 'glob as a hook id' \
    'invalid hook id: *' \
    INPUT_HOOKS='*'

reject 'option-shaped id in skip_hooks' \
    'invalid hook id in skip_hooks: --help' \
    INPUT_RUN_ALL_HOOKS='true' INPUT_SKIP_HOOKS='--help'

reject 'glob in skip_hooks' \
    'invalid hook id in skip_hooks: *' \
    INPUT_RUN_ALL_HOOKS='true' INPUT_SKIP_HOOKS='*'

reject 'non-boolean per_hook_runs' \
    "per_hook_runs must be 'true' or 'false'" \
    INPUT_PER_HOOK_RUNS='yes'

reject 'unknown rust_toolchain_setup' \
    "rust_toolchain_setup must be 'auto', 'true' or 'false'" \
    INPUT_RUST_TOOLCHAIN_SETUP='yes'

# Each component reaches 'rustup component add' as an argument, so an
# option-shaped or shell-shaped entry must stop here, anywhere in the
# list, and so must one longer than any component name.
rust_component_rule='rust_components entries must match'
rust_component_rule="${rust_component_rule} [A-Za-z0-9][A-Za-z0-9_-]*,"
rust_component_rule="${rust_component_rule} up to 64 characters"

reject 'option-shaped rust_components entry' \
    "${rust_component_rule}" \
    INPUT_RUST_COMPONENTS='rustfmt --help'

# shellcheck disable=SC2016 # the literal, unexpanded, is the point
reject 'shell-shaped rust_components entry after a valid one' \
    "${rust_component_rule}" \
    INPUT_RUST_COMPONENTS='rustfmt,$(id)'

reject 'over-long rust_components entry' \
    "${rust_component_rule}" \
    INPUT_RUST_COMPONENTS="r$(printf '%064d' 0)"

reject 'unknown node_setup' \
    "node_setup must be 'auto', 'true' or 'false'" \
    INPUT_NODE_SETUP='yes'

reject 'non-boolean node_install_scripts' \
    "node_install_scripts must be 'true' or 'false'" \
    INPUT_NODE_INSTALL_SCRIPTS='yes'

# node_version reaches actions/setup-node, which would read a range
# as 'the newest release satisfying it'.
node_version_rule='node_version must be a version such as 22,'
node_version_rule="${node_version_rule} 22.11.0 or 22.x, or lts/*,"
node_version_rule="${node_version_rule} lts/<codename>, node, latest"
node_version_rule="${node_version_rule} or current"

reject 'node_version range' \
    "${node_version_rule}" \
    INPUT_NODE_VERSION='>=20'

reject 'node_version wildcard before the patch' \
    "${node_version_rule}" \
    INPUT_NODE_VERSION='22.x.1'

# shellcheck disable=SC2016 # the literal, unexpanded, is the point
reject 'shell-shaped node_version' \
    "${node_version_rule}" \
    INPUT_NODE_VERSION='22$(id)'

# The two #159 guards. Each input fails without its guard as well --
# uvx refuses the version, sha256sum the extra digest record -- so
# testing.yaml alone cannot show that the guard fired.
reject 'multi-line prek_version' \
    'prek_version must not contain control characters' \
    INPUT_RUN_ALL_HOOKS='true' INPUT_PREK_VERSION=$'0.4.14\njunk'

reject 'multi-line config_sha256' \
    'config_sha256 must not contain control characters' \
    INPUT_CONFIG_URL="${config_url}" \
    INPUT_CONFIG_SHA256="${zero_digest}"$'\n'"${zero_digest}"

reject 'prek_version below the floor' \
    'prek_version must be 0.2.20 or newer' \
    INPUT_PREK_VERSION='0.2.19'

# Fails later regardless -- no such prek release exists -- so only
# the step's own refusal shows the comparison caught it.
reject 'prek_version colliding under a packed radix' \
    'prek_version must be 0.2.20 or newer' \
    INPUT_PREK_VERSION='0.1.100020'

# Each side of a range reaches 'git rev-parse'. A side starting '-'
# would read as an option, and '...' is git's symmetric difference,
# a different set of commits from the range the input documents.
reject 'option-shaped side in commit_range' \
    'invalid revision in commit_range: --all' \
    INPUT_COMMIT_RANGE='--all..HEAD'

reject 'symmetric difference as a commit_range' \
    'invalid revision in commit_range: .main' \
    INPUT_COMMIT_RANGE='origin/main...main'

# '.' is legal inside a name, so only the check for a second '..'
# stops the trailing side passing the pattern.
reject 'chained ranges in commit_range' \
    'invalid revision in commit_range: HEAD..main' \
    INPUT_COMMIT_RANGE='HEAD~2..HEAD..main'

reject 'commit_range without a range' \
    "commit_range must be '<from>..<to>'" \
    INPUT_COMMIT_RANGE='HEAD'

reject 'multi-line commit_range' \
    'commit_range must not contain control characters' \
    INPUT_COMMIT_RANGE=$'HEAD~1..HEAD\nHEAD~9..HEAD'

reject 'multi-line rust_components' \
    'rust_components must not contain control characters' \
    INPUT_RUST_COMPONENTS=$'rustfmt\nclippy'

reject 'multi-line node_version' \
    'node_version must not contain control characters' \
    INPUT_NODE_VERSION=$'22\n20'

# --- Result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi
