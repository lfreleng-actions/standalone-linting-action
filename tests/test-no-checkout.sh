#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the no_checkout refusal in the 'Validate inputs' step
# of action.yaml.
#
# With no_checkout 'true' the caller prepares the tree, and the step
# refuses a path_prefix that is not in a git work tree inside the
# workspace. The 'caller-tree' job in .github/workflows/testing.yaml
# can show only that the action FAILED over an empty directory, and
# there it fails later anyway, for want of a configuration file. This
# suite runs the step on its own against prepared workspaces and
# asserts the refusal it prints, so deleting the guard fails here.
#
# The step is EXTRACTED from action.yaml by tests/lib/action-step.sh,
# never copied. Every input starts at its declared default, and a
# case layers VAR=VALUE pairs over that.
#
# Usage: bash tests/test-no-checkout.sh

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

case "${known}" in
    *' INPUT_NO_CHECKOUT '*) ;;
    *)
        echo "ERROR: the 'validate' step in ${action}" >&2
        echo '       does not read no_checkout.' >&2
        exit 1
        ;;
esac

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

# --- Workspaces --------------------------------------------------------

# $1=directory: a repository with one commit, holding 'sub/'.
make_tree() {
    git init -q "$1"
    mkdir "$1/sub"
    printf 'tracked\n' > "$1/sub/file"
    git -C "$1" add sub/file
    git -C "$1" -c user.name='Fixture' -c user.email='fixture@example.com' \
        -c commit.gpgsign=false commit -q -m 'Fixture: Seed'
}

# The workspace IS the caller's tree, as after a checkout to the root.
tree="${workdir}/tree"
make_tree "${tree}"

# An empty workspace: the caller's checkout never ran.
empty="${workdir}/empty"
mkdir -p "${empty}/dir"

# The caller checked out into 'repo/'; the workspace root is no tree.
nested="${workdir}/nested"
mkdir "${nested}"
make_tree "${nested}/repo"
mkdir "${nested}/plain"

# A workspace that is a plain directory inside SOME OTHER repository.
# git finds that repository from the workspace, but it is not the
# caller's tree.
outer="${workdir}/outer"
make_tree "${outer}"
mkdir "${outer}/ws"

passed=0
failed=0
status=0

# Run the step as the runner does: from the workspace root, under
# 'bash --noprofile --norc -eo pipefail', in a clean environment.
# $1 is the workspace; the rest are VAR=VALUE pairs over the
# defaults. Sets 'status'; the output lands in ${workdir}/out.
run_step() {
    local ws="$1" pair
    shift
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
        cd "${ws}"
        env -i PATH="${PATH}" \
            GITHUB_WORKSPACE="${ws}" \
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

# $1 describes the case, $2 is the workspace, the rest are VAR=VALUE
# pairs.
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

refusal='no_checkout is set, but path_prefix is not in a git work tree'
refusal="${refusal} in the workspace:"

# $1 describes the case, $2 is the workspace, the rest are VAR=VALUE
# pairs; INPUT_PATH_PREFIX must be among them. Matched as a whole
# line, so another refusal cannot stand in for this one.
reject() {
    local desc="$1" ws="$2" pair prefix='' line found=0
    shift 2
    for pair in "$@"; do
        case "${pair}" in
            INPUT_PATH_PREFIX=*) prefix="${pair#*=}" ;;
        esac
    done
    run_step "${ws}" "$@"
    while IFS= read -r line; do
        case "${line}" in
            "::error::${refusal} ${prefix} ❌") found=1 ;;
        esac
    done < "${workdir}/out"
    if [ "${status}" -eq 1 ] && [ "${found}" -eq 1 ]; then
        pass "${desc}"
    else
        fail "${desc}" "refusal naming path_prefix '${prefix}'"
    fi
}

# --- Accepted ----------------------------------------------------------

# A guard refusing everything would satisfy every rejection below, so
# a prepared tree must still pass.

accept 'no_checkout over a tree at the workspace root' "${tree}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='.'

accept 'no_checkout over a subdirectory of the tree' "${tree}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='sub'

accept 'no_checkout over a tree in a workspace subdirectory' \
    "${nested}" INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='repo'

# Without no_checkout the action's own checkout, which runs before
# this step, supplies the tree, so the step does not look for one.
accept 'the default no_checkout over an empty workspace' "${empty}" \
    INPUT_PATH_PREFIX='.'

# --- Refused -----------------------------------------------------------

reject 'no_checkout over an empty workspace' "${empty}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='.'

reject 'no_checkout over an empty directory' "${empty}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='dir'

# The checkout step's 'if' compares case-insensitively, so 'True'
# skips the checkout too and must meet the same check.
reject "no_checkout 'True' over an empty workspace" "${empty}" \
    INPUT_NO_CHECKOUT='True' INPUT_PATH_PREFIX='.'

reject 'no_checkout beside a tree checked out elsewhere' "${nested}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='plain'

reject 'no_checkout over a workspace root holding no tree' "${nested}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='.'

reject 'no_checkout in a workspace inside another repository' \
    "${outer}/ws" INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='.'

# --- Result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi
