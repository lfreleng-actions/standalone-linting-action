#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the inputs a caller-prepared tree needs: the
# no_checkout refusal and the cache_hooks check in the 'Validate
# inputs' step of action.yaml, the cache_hooks gate on the 'Cache
# prek hook environments' and 'Cache uv downloads' steps, setup-uv's
# own cache switched off, and a guard that no other action step
# restores or saves a cache.
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
case "${known}" in
    *' INPUT_CACHE_HOOKS '*) ;;
    *)
        echo "ERROR: the 'validate' step in ${action}" >&2
        echo '       does not read cache_hooks.' >&2
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

# --- cache_hooks -------------------------------------------------------

# $1 describes the case, $2 is the workspace, the rest are VAR=VALUE
# pairs. Matched as a whole line, as for reject.
reject_cache_hooks() {
    local desc="$1" ws="$2" line found=0
    shift 2
    run_step "${ws}" "$@"
    while IFS= read -r line; do
        case "${line}" in
            "::error::cache_hooks must be 'true' or 'false' ❌") found=1 ;;
        esac
    done < "${workdir}/out"
    if [ "${status}" -eq 1 ] && [ "${found}" -eq 1 ]; then
        pass "${desc}"
    else
        fail "${desc}" 'the cache_hooks refusal'
    fi
}

accept "cache_hooks 'false' over a caller tree" "${tree}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='.' \
    INPUT_CACHE_HOOKS='false'

accept "cache_hooks 'true' over a caller tree" "${tree}" \
    INPUT_NO_CHECKOUT='true' INPUT_PATH_PREFIX='.' \
    INPUT_CACHE_HOOKS='true'

# Like the other boolean inputs, only the two exact values pass.
for value in 'False' 'TRUE' 'no' '0' '' ' false'; do
    reject_cache_hooks "cache_hooks '${value}'" "${empty}" \
        INPUT_PATH_PREFIX='.' INPUT_CACHE_HOOKS="${value}"
done

# The refusal above means nothing if a cache step ignores the input,
# and only a workflow run can show a step skipping. Check here that
# each cache step exists, is actions/cache, and that its 'if'
# requires cache_hooks to be 'true'.
for cache_step in 'Cache prek hook environments' 'Cache uv downloads'; do
status=0
"${PY_RUN[@]}" - "${action}" "${cache_step}" \
    > "${workdir}/out" 2>&1 <<'PYEOF' || status=$?
import re
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    action = yaml.safe_load(handle)
steps = [
    step
    for step in (action.get('runs') or {}).get('steps') or []
    if isinstance(step, dict)
    and step.get('name') == sys.argv[2]
]
if len(steps) != 1:
    sys.exit(f'expected one cache step, found {len(steps)}')
step = steps[0]
if not str(step.get('uses', '')).startswith('actions/cache@'):
    sys.exit(f"the cache step uses {step.get('uses')!r}")
condition = ' '.join(str(step.get('if', '')).split())
clauses = [clause.strip() for clause in condition.split('&&')]
if '||' in condition or not any(
    re.fullmatch(r"inputs\.cache_hooks\s*==\s*'true'", clause)
    for clause in clauses
):
    sys.exit(f"the cache step's if does not require cache_hooks: "
             f'{condition!r}')
PYEOF
if [ "${status}" -eq 0 ]; then
    pass "'${cache_step}' requires cache_hooks"
else
    fail "'${cache_step}' requires cache_hooks" 'a gated cache step'
fi
done

# setup-uv restores and saves uv's cache unless told not to, and its
# key and its 'auto' events are its own. The 'Cache uv downloads'
# step caches the directory the action's uv calls name instead, so
# setup-uv's enable-cache must be off.
status=0
"${PY_RUN[@]}" - "${action}" > "${workdir}/out" 2>&1 <<'PYEOF' || status=$?
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    action = yaml.safe_load(handle)
steps = [
    step
    for step in (action.get('runs') or {}).get('steps') or []
    if isinstance(step, dict) and step.get('name') == 'Set up uv'
]
if len(steps) != 1:
    sys.exit(f'expected one setup-uv step, found {len(steps)}')
step = steps[0]
if not str(step.get('uses', '')).startswith('astral-sh/setup-uv@'):
    sys.exit(f"the setup-uv step uses {step.get('uses')!r}")
value = (step.get('with') or {}).get('enable-cache')
if not (value is False or str(value).lower() == 'false'):
    sys.exit(f"setup-uv's enable-cache is {value!r}, not false")
PYEOF
if [ "${status}" -eq 0 ]; then
    pass "setup-uv's own cache is off"
else
    fail "setup-uv's own cache is off" 'enable-cache false'
fi

# cache_hooks 'false' promises that NO step restores or saves a
# cache. Every 'uses:' step must be one this guard knows, with its
# cache tied to cache_hooks or switched off, so an action added or
# reconfigured later cannot reopen the gap silently. An action the
# guard does not know fails it until someone classifies it here.
status=0
"${PY_RUN[@]}" - "${action}" > "${workdir}/out" 2>&1 <<'PYEOF' || status=$?
import re
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    action = yaml.safe_load(handle)

gated_if = re.compile(r"inputs\.cache_hooks\s*==\s*'true'")


def if_requires_cache_hooks(step):
    condition = ' '.join(str(step.get('if', '')).split())
    if '||' in condition:
        return False
    return any(
        gated_if.fullmatch(clause.strip())
        for clause in condition.split('&&')
    )


def is_off(value, off):
    return value is off or str(value).lower() == str(off).lower()


problems = []
for step in (action.get('runs') or {}).get('steps') or []:
    if not isinstance(step, dict) or 'uses' not in step:
        continue
    uses = str(step['uses'])
    name = step.get('name', uses)
    action_ref = uses.split('@', 1)[0]
    inputs = step.get('with') or {}
    if action_ref == 'actions/checkout':
        continue
    if action_ref in ('actions/cache', 'actions/cache/restore',
                      'actions/cache/save'):
        if not if_requires_cache_hooks(step):
            problems.append(f"{name}: {action_ref} not gated by "
                            f"cache_hooks")
    elif action_ref == 'astral-sh/setup-uv':
        if not is_off(inputs.get('enable-cache'), False):
            problems.append(f"{name}: enable-cache is "
                            f"{inputs.get('enable-cache')!r}")
    elif action_ref == 'actions/setup-node':
        if not is_off(inputs.get('package-manager-cache'), False):
            problems.append(f'{name}: package-manager-cache is not false')
        if inputs.get('cache') not in (None, ''):
            problems.append(f'{name}: cache is {inputs.get("cache")!r}')
    elif action_ref == 'oven-sh/setup-bun':
        if not is_off(inputs.get('no-cache'), True):
            problems.append(f'{name}: no-cache is not true')
    else:
        problems.append(f'{name}: {action_ref} is unknown to this guard')
if problems:
    sys.exit('\n'.join(problems))
PYEOF
if [ "${status}" -eq 0 ]; then
    pass 'no action step caches outside cache_hooks'
else
    fail 'no action step caches outside cache_hooks' \
        'every caching step tied to cache_hooks or off'
fi

# --- Result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi
