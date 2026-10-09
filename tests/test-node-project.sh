#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Fixtures for the 'Plan Node.js project preparation' and 'Prepare
# Node.js project' steps in action.yaml.
#
# The plan step decides whether a repository is a Node.js project,
# which Node.js version it pins and which package manager its tracked
# lockfile belongs to; the prepare step installs. testing.yaml runs
# both for real, but a runner cannot show WHICH install command ran,
# nor reach every refusal cheaply. This suite runs each step on its
# own, against stand-in node, npm, corepack and bun binaries that
# record every call, and asserts the plan, the calls, the outputs and
# the refusals. A chained case feeds the plan's outputs to the prepare
# step through the env mapping action.yaml declares.
#
# The steps are EXTRACTED from action.yaml by tests/lib/action-step.sh,
# never copied. Workspaces are real git repositories, since detection
# asks git which files are tracked.
#
# Usage: tests/test-node-project.sh

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

# load_step <id> <prefix>: extracts the step, sets <prefix>_script,
# <prefix>_env (the default environment) and <prefix>_known.
load_step() {
    local id="$1" prefix="$2" entry known=' '
    local -a env_list=()
    action_step_extract "${action}" "${id}" "${workdir}/${id}.sh" \
        "${workdir}/${id}.defaults"
    while IFS= read -r -d '' entry; do
        env_list+=("${entry}")
        known="${known}${entry%%=*} "
    done < "${workdir}/${id}.defaults"
    if [ ! -s "${workdir}/${id}.sh" ] || [ "${#env_list[@]}" -eq 0 ]; then
        echo "ERROR: the '${id}' step in ${action}" >&2
        echo '       has no script, or reads no inputs.' >&2
        exit 1
    fi
    printf -v "${prefix}_script" '%s' "${workdir}/${id}.sh"
    printf -v "${prefix}_known" '%s' "${known}"
    eval "${prefix}_env=(\"\${env_list[@]}\")"
}

plan_script='' plan_known='' node_script='' node_known=''
plan_env=() node_env=()
load_step node_plan plan
load_step node node

# Which prepare-step variable carries which plan output, read from
# action.yaml so a renamed output cannot pass here and break there.
plan_map="$("${PY_RUN[@]}" - "${action}" <<'PYEOF'
import re
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    action = yaml.safe_load(handle)
pattern = re.compile(r'\$\{\{\s*steps\.node_plan\.outputs\.([A-Za-z0-9_-]+)\s*\}\}')
for step in action['runs']['steps']:
    if isinstance(step, dict) and step.get('id') == 'node':
        for name, value in (step.get('env') or {}).items():
            match = pattern.fullmatch(str(value))
            if match:
                print(f'{name}={match.group(1)}')
PYEOF
)"
if [ -z "${plan_map}" ]; then
    echo "ERROR: the 'node' step reads no node_plan outputs" >&2
    exit 1
fi

bash_bin="$(command -v bash)"

# The steps' PATH holds links to the tools they may call and nothing
# else, so 'node is absent' is true whatever the machine running this
# suite has installed. A tool a step starts to need without being
# listed here fails a case, loudly.
toolbin="${workdir}/toolbin"

mkdir "${toolbin}"

# The plan step reads package.json with Python through uv, which the
# action provisions. This stand-in accepts only the step's invocation
# and runs its script with the Python running this suite, so no case
# needs uv, or reaches a network. jq is deliberately absent: the
# action must not need it.
# sys.executable: a 'python3' on PATH may be a shim script needing
# more of PATH than a case gives it.
python_bin="$(python3 -I -c 'import sys; print(sys.executable)' \
    2> /dev/null || true)"
if [ -z "${python_bin}" ]; then
    echo 'ERROR: python3 is needed to run this suite' >&2
    exit 1
fi
cat > "${toolbin}/uv" <<EOF
#!${bash_bin}
set -u
if [ "\$*" != "run --no-config --no-project python - \${6-}" ] ||
    [ "\$#" -ne 6 ]; then
    echo "stand-in uv: unexpected call: \$*" >&2
    exit 2
fi
shift 4
exec '${python_bin}' -I "\$@"
EOF
chmod +x "${toolbin}/uv"
for tool in awk git grep sed tr; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        echo "ERROR: ${tool} is needed to run this suite" >&2
        exit 1
    fi
    ln -s "$(command -v "${tool}")" "${toolbin}/${tool}"
done

# Stand-ins. Each package manager records
# '<cwd>|<COREPACK_ENABLE_DOWNLOAD_PROMPT>|<COREPACK_ENABLE_AUTO_PIN>|<argv>'
# and fails when FAKE_INSTALL_FAIL is set. node prints FAKE_NODE_VERSION.
# Each lives in a directory of its own, so a case chooses which exist.
# A global npm install of corepack puts the corepack stand-in in
# npm-global, which is on every case's PATH and emptied per case,
# unless FAKE_NPM_NO_COREPACK is set.
fake() {
    # $1=name
    mkdir -p "${workdir}/fake-$1"
    cat > "${workdir}/fake-$1/$1" <<EOF
#!${bash_bin}
set -u
printf '%s|%s|%s|%s\n' "\$PWD" "\${COREPACK_ENABLE_DOWNLOAD_PROMPT-unset}" \\
    "\${COREPACK_ENABLE_AUTO_PIN-unset}" "$1 \$*" >> "\$FAKE_LOG"
[ -z "\${FAKE_INSTALL_FAIL-}" ] || exit 1
# Under NODE_ENV=production a real install drops devDependencies.
[ -z "\${NODE_ENV+set}" ] || { echo 'NODE_ENV reached $1' >&2; exit 3; }
if [ '$1' = 'npm' ] && [ "\${1-} \${2-}" = 'install --global' ] &&
    [ -z "\${FAKE_NPM_NO_COREPACK-}" ]; then
    '$(command -v cp)' '${workdir}/fake-corepack/corepack' \
        '${workdir}/npm-global/'
fi
EOF
    chmod +x "${workdir}/fake-$1/$1"
}
fake npm
fake corepack
fake bun
mkdir "${workdir}/fake-node"
cat > "${workdir}/fake-node/node" <<EOF
#!${bash_bin}
set -u
if [ "\$*" = '--version' ]; then
    printf '%s\n' "\${FAKE_NODE_VERSION-v22.11.0}"
    exit 0
fi
echo "stand-in node: unexpected call: \$*" >&2
exit 2
EOF
chmod +x "${workdir}/fake-node/node"

# Workspaces. git runs with an empty HOME and no system config, so
# the configuration of the machine running the suite cannot leak in.
export HOME="${workdir}/home" GIT_CONFIG_NOSYSTEM=1
mkdir "${HOME}"
ws_count=0
ws=''

# project [+]<name>=<content>...: a fresh git repository holding each
# file, tracked unless its name starts '+'. Sets ws to its real path.
project() {
    local spec name dir
    ws_count=$((ws_count + 1))
    dir="${workdir}/ws-${ws_count}"
    mkdir -p "${dir}"
    git -C "${dir}" init -q
    for spec in "$@"; do
        name="${spec%%=*}"
        mkdir -p "$(dirname "${dir}/${name#+}")"
        printf '%s' "${spec#*=}" > "${dir}/${name#+}"
        case "${name}" in
            +*) ;;
            *) git -C "${dir}" add -- "${name}" ;;
        esac
    done
    ws="$(cd "${dir}" && pwd -P)"
}

# The same, outside any git repository.
plain_dir() {
    local spec
    ws_count=$((ws_count + 1))
    ws="${workdir}/ws-${ws_count}"
    mkdir -p "${ws}"
    for spec in "$@"; do
        printf '%s' "${spec#*=}" > "${ws}/${spec%%=*}"
    done
    ws="$(cd "${ws}" && pwd -P)"
}

pkg='{"name": "fixture", "version": "1.0.0"}'
lock_npm='{"lockfileVersion": 3}'
lock_yarn1='# yarn lockfile v1'
lock_berry=$'__metadata:\n  version: 8'
lock_pnpm="lockfileVersion: '9.0'"

passed=0
failed=0
status=0
errors=()

# run_step <plan|node> <workspace> <fakes, comma separated, or ''>
#     [VAR=VALUE...]
#
# Runs the step as the runner does, from the workspace root, under
# 'bash --noprofile --norc -eo pipefail', in a clean environment.
# Every input starts at its default and every plan output empty;
# INPUT_*/PLAN_* pairs override them, FAKE_* pairs configure the
# stand-ins.
run_step() {
    local which="$1" workspace="$2" fakes="$3" pair
    local path="${workdir}/npm-global:${toolbin}"
    local script known fake_name
    local -a env_list
    shift 3
    if [ "${which}" = 'plan' ]; then
        script="${plan_script}" known="${plan_known}"
        env_list=("${plan_env[@]}")
    else
        script="${node_script}" known="${node_known}"
        env_list=("${node_env[@]}")
    fi
    for pair in "$@"; do
        case "${pair}" in
            FAKE_*=* | NODE_ENV=*) ;;
            *)
                case "${known}" in
                    *" ${pair%%=*} "*) ;;
                    *)
                        echo "ERROR: the ${which} step does not read" \
                            "${pair%%=*}" >&2
                        exit 1
                        ;;
                esac
                ;;
        esac
    done
    IFS=',' read -ra fake_names <<< "${fakes}"
    for fake_name in "${fake_names[@]+"${fake_names[@]}"}"; do
        path="${workdir}/fake-${fake_name}:${path}"
    done
    rm -rf "${workdir}/case" "${workdir}/npm-global"
    mkdir "${workdir}/npm-global"
    mkdir -p "${workdir}/case"
    : > "${workdir}/case/calls.log"
    : > "${workdir}/case/output"
    : > "${workdir}/case/summary"
    status=0
    (
        cd "${workspace}"
        env -i PATH="${path}" HOME="${HOME}" GIT_CONFIG_NOSYSTEM=1 \
            GITHUB_WORKSPACE="${workspace}" \
            GITHUB_OUTPUT="${workdir}/case/output" \
            GITHUB_STEP_SUMMARY="${workdir}/case/summary" \
            FAKE_LOG="${workdir}/case/calls.log" \
            "${env_list[@]}" "$@" \
            "${bash_bin}" --noprofile --norc -eo pipefail "${script}"
    ) > "${workdir}/case/out" 2>&1 || status=$?
}

# Runs the plan, then the prepare step with the plan's outputs mapped
# onto its environment as action.yaml maps them. The prepare step
# runs only when the plan set setup=true, as in the action.
run_chain() {
    local workspace="$1" fakes="$2" line var key value
    local -a plan_pairs=() node_pairs=()
    shift 2
    for pair in "$@"; do
        case "${pair}" in
            INPUT_NODE_INSTALL_SCRIPTS=*) node_pairs+=("${pair}") ;;
            INPUT_NODE_VERSION=*) plan_pairs+=("${pair}") ;;
            *) plan_pairs+=("${pair}") node_pairs+=("${pair}") ;;
        esac
    done
    run_step plan "${workspace}" '' "${plan_pairs[@]+"${plan_pairs[@]}"}"
    [ "${status}" -eq 0 ] || return 0
    [ "$(output_value setup)" = 'true' ] || return 0
    cp "${workdir}/case/output" "${workdir}/plan-output"
    while IFS= read -r line; do
        var="${line%%=*}" key="${line#*=}"
        value="$(sed -n "s/^${key}=//p" "${workdir}/plan-output")"
        node_pairs+=("${var}=${value}")
    done <<< "${plan_map}"
    run_step node "${workspace}" "${fakes}" "${node_pairs[@]}"
}

check() {
    errors+=("$1")
}

expect_status() {
    [ "${status}" -eq "$1" ] ||
        check "exit status ${status}, expected $1"
}

# A whole line of the step's output, exactly.
expect_line() {
    grep -qxF -- "$1" "${workdir}/case/out" ||
        check "no output line: $1"
}

# An output record's value, or '<unset>' when the step wrote none.
output_value() {
    if grep -q "^$1=" "${workdir}/case/output"; then
        sed -n "s/^$1=//p" "${workdir}/case/output"
    else
        printf '<unset>'
    fi
}

# expect_outputs name=value...: each record, exactly.
expect_outputs() {
    local pair got
    for pair in "$@"; do
        got="$(output_value "${pair%%=*}")"
        [ "${got}" = "${pair#*=}" ] ||
            check "output ${pair%%=*}='${got}', expected '${pair#*=}'"
    done
}

# The stand-ins' call log, exactly. No arguments means no package
# manager was called.
expect_calls() {
    local expected=''
    if [ "$#" -gt 0 ]; then
        expected="$(printf '%s\n' "$@")"
    fi
    [ "$(cat "${workdir}/case/calls.log")" = "${expected}" ] ||
        check 'unexpected package manager calls'
}

expect_summary() {
    grep -qF -- "$1" "${workdir}/case/summary" ||
        check "summary lacks: $1"
}

expect_no_summary() {
    [ ! -s "${workdir}/case/summary" ] ||
        check 'wrote a job summary'
}

verdict() {
    if [ "${#errors[@]}" -eq 0 ]; then
        passed=$((passed + 1))
        printf 'PASS: %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL: %s\n' "$1"
        printf '      %s\n' "${errors[@]}"
        echo '      output:'
        sed 's/^/        /' "${workdir}/case/out"
        echo '      outputs:'
        sed 's/^/        /' "${workdir}/case/output"
        echo '      calls:'
        sed 's/^/        /' "${workdir}/case/calls.log"
    fi
    errors=()
}

# --- Plan: not a Node.js project, or turned off ----------------------

# The estate-wide case: existing callers must see no change at all.
project README.md=readme +package.json="${pkg}" +package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_status 0
expect_line 'No tracked package.json in path_prefix; not preparing Node.js 💬'
expect_outputs setup=false manager='<unset>'
expect_no_summary
verdict 'auto, package.json untracked: not a Node.js project'

plain_dir package.json="${pkg}" package-lock.json="${lock_npm}"
ws_nogit="${ws}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs setup=false
verdict 'auto, not a git repository: not a Node.js project'

# A package.json in a subdirectory is not path_prefix's.
project web/package.json="${pkg}" web/package-lock.json="${lock_npm}"
ws_web="${ws}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs setup=false
verdict 'auto, package.json below path_prefix only: not prepared'

project package.json="${pkg}" package-lock.json="${lock_npm}"
ws_npm="${ws}"
run_step plan "${ws}" '' INPUT_NODE_SETUP='false'
expect_status 0
expect_line 'node_setup is false; not preparing Node.js 💬'
expect_outputs setup=false
expect_no_summary
verdict 'false, Node.js project: not prepared'

# --- Plan: package manager -------------------------------------------

run_step plan "${ws_npm}" ''
expect_status 0
expect_outputs setup=true manager=npm lockfile=package-lock.json \
    manager_version='' version='' version_source='' skip_reason=''
verdict 'auto, npm lockfile: npm'

run_step plan "${ws_web}" '' INPUT_PATH_PREFIX='web'
expect_status 0
expect_outputs setup=true manager=npm lockfile=package-lock.json
verdict 'path_prefix holding the project: npm'

project package.json="${pkg}" npm-shrinkwrap.json="${lock_npm}"
run_step plan "${ws}" ''
expect_outputs setup=true manager=npm lockfile=npm-shrinkwrap.json
verdict 'npm-shrinkwrap.json: npm'

# 'npm ci' follows npm-shrinkwrap.json over a package-lock.json.
project package.json="${pkg}" package-lock.json="${lock_npm}" \
    npm-shrinkwrap.json="${lock_npm}"
run_step plan "${ws}" ''
expect_outputs setup=true manager=npm lockfile=npm-shrinkwrap.json
verdict 'both npm lockfiles: npm-shrinkwrap.json, as npm ci reads'

project package.json="${pkg}" yarn.lock="${lock_yarn1}"
ws_yarn1="${ws}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs setup=true manager=yarn lockfile=yarn.lock manager_version=''
verdict 'Yarn 1 lockfile: yarn'

project package.json='{"packageManager": "yarn@4.5.3"}' yarn.lock="${lock_berry}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs manager=yarn-berry lockfile=yarn.lock manager_version=4.5.3
verdict 'Yarn 4 named in packageManager: yarn-berry'

project package.json='{"packageManager": "yarn@1.22.22"}' yarn.lock="${lock_yarn1}"
run_step plan "${ws}" ''
expect_outputs manager=yarn manager_version=1.22.22
verdict 'Yarn 1 named in packageManager: yarn'

# Corepack falls back to Yarn 1, which cannot read this lockfile.
project package.json="${pkg}" yarn.lock="${lock_berry}"
ws_berry_unnamed="${ws}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs setup=true manager='' lockfile=''
expect_line '::warning::Not installing dependencies: yarn.lock is in the Yarn 2+ format; name the Yarn version in package.json packageManager'
verdict 'auto, Yarn 2+ lockfile, no packageManager: warned, no install'

run_step plan "${ws_berry_unnamed}" '' INPUT_NODE_SETUP='true'
expect_status 1
expect_line "::error::node_setup is 'true' but yarn.lock is in the Yarn 2+ format; name the Yarn version in package.json packageManager ❌"
expect_summary '❌ Failed at plan'
verdict 'true, Yarn 2+ lockfile, no packageManager: refused'

# A sha512 hash, as Corepack writes it: 128 hex digits.
pnpm_pm="pnpm@9.15.0+sha512.$(printf '%0128d' 0)"
project package.json="{\"packageManager\": \"${pnpm_pm}\"}" pnpm-lock.yaml="${lock_pnpm}"
ws_pnpm="${ws}"
run_step plan "${ws}" ''
expect_outputs manager=pnpm lockfile=pnpm-lock.yaml manager_version=9.15.0
verdict 'pnpm with a hashed packageManager: version without the hash'

project package.json="${pkg}" bun.lock='{}'
ws_bun="${ws}"
run_step plan "${ws}" ''
expect_outputs manager=bun lockfile=bun.lock manager_version=''
verdict 'bun.lock: bun'

project package.json='{"packageManager": "bun@1.2.3"}' bun.lockb='x'
run_step plan "${ws}" ''
expect_outputs manager=bun lockfile=bun.lockb manager_version=1.2.3
verdict 'bun.lockb with packageManager: bun at that version'

project package.json='{"packageManager": "npm@10.9.0"}' package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_outputs manager=npm manager_version=''
verdict 'npm named in packageManager: the bundled npm'

# Two package managers' lockfiles: packageManager decides.
project package.json="${pkg}" package-lock.json="${lock_npm}" yarn.lock="${lock_yarn1}"
ws_two="${ws}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs setup=true manager=''
expect_line '::warning::Not installing dependencies: lockfiles for npm yarn are all tracked; name one in package.json packageManager'
verdict 'auto, two lockfiles, no packageManager: warned, no install'

run_step plan "${ws_two}" '' INPUT_NODE_SETUP='true'
expect_status 1
verdict 'true, two lockfiles, no packageManager: refused'

project package.json='{"packageManager": "yarn@1.22.22"}' \
    package-lock.json="${lock_npm}" yarn.lock="${lock_yarn1}"
run_step plan "${ws}" ''
expect_outputs manager=yarn lockfile=yarn.lock
verdict 'two lockfiles, packageManager names one: that one'

project package.json='{"packageManager": "pnpm@9.15.0"}' package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_outputs setup=true manager=''
expect_line '::warning::Not installing dependencies: package.json names pnpm, and no pnpm lockfile is tracked'
verdict 'packageManager naming a manager with no lockfile: no install'

# shellcheck disable=SC2016 # the literal, unexpanded, is the point
for bad in 'yarn@berry' 'yarn@4' '$(id)@1.0.0' 'deno@2.0.0' 'yarn@1.0.0 x'; do
    project package.json="{\"packageManager\": \"${bad}\"}" yarn.lock="${lock_yarn1}"
    run_step plan "${ws}" ''
    expect_status 0
    expect_outputs setup=true manager='' manager_version=''
    expect_line '::warning::Not installing dependencies: package.json packageManager is not <npm|yarn|pnpm|bun>@<x.y.z>'
    verdict "unacceptable packageManager, no install: '${bad}'"
done

# --- Plan: missing lockfile ------------------------------------------

project package.json="${pkg}"
ws_nolock="${ws}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs setup=true manager='' lockfile='' \
    skip_reason='no lockfile is tracked beside package.json; commit the one your package manager writes'
expect_line '::warning::Not installing dependencies: no lockfile is tracked beside package.json; commit the one your package manager writes'
verdict 'auto, no lockfile: warned, no install'

run_step plan "${ws_nolock}" '' INPUT_NODE_SETUP='true'
expect_status 1
expect_line "::error::node_setup is 'true' but no lockfile is tracked beside package.json; commit the one your package manager writes ❌"
expect_summary '❌ Failed at plan'
expect_outputs setup='<unset>'
verdict 'true, no lockfile: refused'

project package.json="${pkg}" +package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_outputs setup=true manager=''
verdict 'untracked lockfile: not followed'

# --- Plan: Node.js version -------------------------------------------

project package.json="${pkg}" package-lock.json="${lock_npm}" \
    .nvmrc=$'# pinned\n  v20.11.1  \n18\n' .node-version='21'
ws_nvmrc="${ws}"
run_step plan "${ws}" ''
expect_outputs version=20.11.1 version_source=.nvmrc
verdict '.nvmrc: first value, comment and v stripped'

run_step plan "${ws_nvmrc}" '' INPUT_NODE_VERSION='lts/*'
expect_outputs version='lts/*' version_source=node_version
verdict 'node_version wins over .nvmrc'

project package.json="${pkg}" package-lock.json="${lock_npm}" \
    .nvmrc=$'# nothing\n\n' .node-version='22.x'
run_step plan "${ws}" ''
expect_outputs version=22.x version_source=.node-version
verdict 'comment-only .nvmrc: .node-version'

project package.json="${pkg}" package-lock.json="${lock_npm}" \
    +.nvmrc='18' .node-version='lts/iron'
run_step plan "${ws}" ''
expect_outputs version=lts/iron version_source=.node-version
verdict 'untracked .nvmrc: not followed'

project package.json='{"engines": {"node": "22"}}' package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_outputs version=22 version_source='package.json engines.node'
verdict 'plain engines.node: followed'

project package.json='{"engines": {"node": ">=20"}}' package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs version='' version_source=''
expect_line "::notice::package.json engines.node is a range, not a version, so the runner's Node.js runs; pin one in .nvmrc or node_version"
verdict 'engines.node range: the runner default'

project package.json='{"engines": "node"}' package-lock.json="${lock_npm}"
run_step plan "${ws}" ''
expect_status 0
expect_outputs version='' manager=npm
verdict 'engines that is not an object: ignored'

# A version read from the repository reaches setup-node; neither shell
# syntax nor a range may get through.
# shellcheck disable=SC2016 # the literal, unexpanded, is the point
for bad in '$(touch pwned)' '>=20' '20 || 22' 'lts/-1' '-v' '22.x.1' \
    '2 2'; do
    project package.json="${pkg}" package-lock.json="${lock_npm}" .nvmrc="${bad}"
    run_step plan "${ws}" ''
    expect_status 1
    expect_line "::error::.nvmrc names a Node.js version this action does not accept; use a version such as 22 or 22.11.0, lts/*, or set node_version ❌"
    expect_outputs setup='<unset>'
    verdict "unacceptable .nvmrc refused: '${bad}'"
done

# --- Plan: unreadable package.json, and 'true' without one -----------

for bad in '[]' '{"name": ' ''; do
    project package.json="${bad}" package-lock.json="${lock_npm}"
    run_step plan "${ws}" ''
    expect_status 1
    expect_line '::error::package.json in path_prefix is not a JSON object ❌'
    verdict "package.json that is not a JSON object refused: '${bad}'"
done

project README.md=readme
ws_plain="${ws}"
run_step plan "${ws}" '' INPUT_NODE_SETUP='true'
expect_status 0
expect_outputs setup=true manager='' skip_reason='' version=''
verdict 'true, no package.json: Node.js only'

run_step plan "${ws_nogit}" '' INPUT_NODE_SETUP='true'
expect_status 0
expect_outputs setup=true manager=npm lockfile=package-lock.json
verdict 'true, not a git repository: files present count'

# --- Prepare: installs -----------------------------------------------

run_step node "${ws_npm}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json
expect_status 0
expect_outputs version=v22.11.0 prepared=true
expect_calls "${ws_npm}|0|0|npm ci --no-audit --no-fund --include=dev --ignore-scripts"
expect_summary '✅ Prepared for the hooks'
expect_summary "| Node.js | \`v22.11.0\` (the runner's; the project pins no version) |"
expect_summary "| Dependencies | ✅ \`npm ci --no-audit --no-fund --include=dev --ignore-scripts\` from \`package-lock.json\` |"
verdict 'npm: npm ci, scripts off'

run_step node "${ws_npm}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json INPUT_NODE_INSTALL_SCRIPTS='true'
expect_status 0
expect_calls "${ws_npm}|0|0|npm ci --no-audit --no-fund --include=dev"
verdict 'node_install_scripts true: scripts on'

run_step node "${ws_yarn1}" node,corepack PLAN_MANAGER=yarn \
    PLAN_LOCKFILE=yarn.lock
expect_status 0
expect_outputs prepared=true
expect_calls "${ws_yarn1}|0|0|corepack yarn install --frozen-lockfile --non-interactive --production=false --ignore-scripts"
verdict 'Yarn 1: --frozen-lockfile through Corepack'

run_step node "${ws_yarn1}" node,corepack PLAN_MANAGER=yarn-berry \
    PLAN_MANAGER_VERSION=4.5.3 PLAN_LOCKFILE=yarn.lock
expect_status 0
expect_calls "${ws_yarn1}|0|0|corepack yarn install --immutable --mode=skip-build"
verdict 'Yarn 2+: --immutable, builds skipped'

run_step node "${ws_yarn1}" node,corepack PLAN_MANAGER=yarn-berry \
    PLAN_LOCKFILE=yarn.lock INPUT_NODE_INSTALL_SCRIPTS='true'
expect_calls "${ws_yarn1}|0|0|corepack yarn install --immutable"
verdict 'Yarn 2+ with scripts: builds run'

# Yarn 2 has no --mode: it skips builds with --skip-builds.
run_step node "${ws_yarn1}" node,corepack PLAN_MANAGER=yarn-berry \
    PLAN_MANAGER_VERSION=2.4.3 PLAN_LOCKFILE=yarn.lock
expect_status 0
expect_calls "${ws_yarn1}|0|0|corepack yarn install --immutable --skip-builds"
verdict 'Yarn 2: --immutable, builds skipped with --skip-builds'

run_step node "${ws_pnpm}" node,corepack PLAN_MANAGER=pnpm \
    PLAN_LOCKFILE=pnpm-lock.yaml
expect_status 0
expect_calls "${ws_pnpm}|0|0|corepack pnpm install --frozen-lockfile --prod=false --ignore-scripts"
verdict 'pnpm: --frozen-lockfile through Corepack'

# An ambient NODE_ENV=production would drop the devDependencies.
run_step node "${ws_npm}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json NODE_ENV=production
expect_status 0
expect_outputs version=v22.11.0 prepared=true
expect_calls "${ws_npm}|0|0|npm ci --no-audit --no-fund --include=dev --ignore-scripts"
verdict 'NODE_ENV=production: cleared for the install'

# Node.js 25 and later bundle no Corepack: npm installs a pinned one.
run_step node "${ws_pnpm}" node,npm PLAN_MANAGER=pnpm \
    PLAN_LOCKFILE=pnpm-lock.yaml FAKE_NODE_VERSION=v25.0.0
expect_status 0
expect_outputs version=v25.0.0 prepared=true
expect_calls \
    "${ws_pnpm}|0|0|npm install --global --ignore-scripts --no-audit --no-fund corepack@0.36.0" \
    "${ws_pnpm}|0|0|corepack pnpm install --frozen-lockfile --prod=false --ignore-scripts"
expect_summary "| Corepack | ✅ \`corepack@0.36.0\` (none on PATH for \`v25.0.0\`) |"
verdict 'no Corepack on PATH: pinned release installed, then used'

run_step node "${ws_bun}" node,bun PLAN_MANAGER=bun PLAN_LOCKFILE=bun.lock
expect_status 0
expect_calls "${ws_bun}|0|0|bun install --frozen-lockfile --ignore-scripts"
verdict 'Bun: --frozen-lockfile'

run_step node "${ws_web}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json INPUT_PATH_PREFIX='web'
expect_status 0
expect_calls "${ws_web}/web|0|0|npm ci --no-audit --no-fund --include=dev --ignore-scripts"
verdict 'path_prefix: installed there'

run_step node "${ws_nvmrc}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json PLAN_VERSION=20.11.1 \
    PLAN_VERSION_SOURCE=.nvmrc FAKE_NODE_VERSION=v20.11.1
expect_status 0
expect_outputs version=v20.11.1
expect_summary "| Node.js | \`v20.11.1\` (from .nvmrc: 20.11.1) |"
verdict 'pinned version: reported with its source'

# --- Prepare: not prepared, without failing --------------------------

run_step node "${ws_nolock}" node,npm \
    PLAN_SKIP_REASON='no lockfile is tracked beside package.json'
expect_status 0
expect_outputs version=v22.11.0 prepared=false
expect_calls
expect_summary '⚠️ Not prepared: hooks run without the dependencies'
expect_summary '- Dependencies not installed: no lockfile is tracked beside package.json'
verdict 'plan skipped the install: Node.js only, not prepared'

run_step node "${ws_plain}" node INPUT_NODE_SETUP='true'
expect_status 0
expect_outputs version=v22.11.0 prepared=true
expect_calls
expect_summary '✅ Node.js selected; no package.json to install from'
verdict 'true, nothing to install: prepared'

run_step node "${ws_npm}" npm PLAN_MANAGER=npm PLAN_LOCKFILE=package-lock.json
expect_status 0
expect_outputs version='<unset>' prepared=false
expect_calls
expect_line '::notice::Node.js is not on PATH and no version is pinned; the Node.js project was not prepared'
expect_summary '⚠️ Not prepared: Node.js is not on PATH'
verdict 'auto, no Node.js: notice, success'

run_step node "${ws_pnpm}" node PLAN_MANAGER=pnpm PLAN_LOCKFILE=pnpm-lock.yaml \
    FAKE_NODE_VERSION=v25.0.0
expect_status 0
expect_outputs version=v25.0.0 prepared=false
expect_calls
expect_line '::warning::Not installing dependencies: corepack is not on PATH for Node.js v25.0.0, and pnpm needs it; installing corepack@0.36.0 with npm failed; it supports Node.js ^22.22.2 || ^24.15.0 || >=26.0.0'
verdict 'auto, no Corepack and no npm: warned, not prepared'

run_step node "${ws_pnpm}" node,npm PLAN_MANAGER=pnpm \
    PLAN_LOCKFILE=pnpm-lock.yaml FAKE_NODE_VERSION=v25.0.0 \
    FAKE_NPM_NO_COREPACK=1
expect_status 0
expect_outputs version=v25.0.0 prepared=false
expect_calls "${ws_pnpm}|0|0|npm install --global --ignore-scripts --no-audit --no-fund corepack@0.36.0"
expect_line '::warning::Not installing dependencies: corepack@0.36.0 installed, but corepack is not on PATH'
verdict 'auto, Corepack installed off PATH: warned, not prepared'

# --- Prepare: refused ------------------------------------------------

run_step node "${ws_npm}" npm INPUT_NODE_SETUP='true' PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json
expect_status 1
expect_line "::error::node_setup is 'true' but Node.js is not on PATH; set node_version ❌"
expect_summary '❌ Failed at setup'
verdict 'true, no Node.js: refused'

run_step node "${ws_pnpm}" node,npm INPUT_NODE_SETUP='true' \
    PLAN_MANAGER=pnpm PLAN_LOCKFILE=pnpm-lock.yaml FAKE_INSTALL_FAIL=1
expect_status 1
expect_outputs version=v22.11.0 prepared='<unset>'
expect_calls "${ws_pnpm}|0|0|npm install --global --ignore-scripts --no-audit --no-fund corepack@0.36.0"
expect_line "::error::node_setup is 'true' but corepack is not on PATH for Node.js v22.11.0, and pnpm needs it; installing corepack@0.36.0 with npm failed; it supports Node.js ^22.22.2 || ^24.15.0 || >=26.0.0 ❌"
verdict 'true, Corepack install failed: refused'

run_step node "${ws_bun}" node PLAN_MANAGER=bun PLAN_LOCKFILE=bun.lock
expect_status 1
expect_line '::error::bun is not on PATH after setting it up ❌'
verdict 'Bun missing after setup: refused'

run_step node "${ws_npm}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json FAKE_INSTALL_FAIL=1
expect_status 1
expect_outputs version=v22.11.0 prepared='<unset>'
expect_line '::error::npm ci --no-audit --no-fund --include=dev --ignore-scripts failed in .; is package-lock.json in sync with package.json? ❌'
expect_summary '❌ Failed at install'
verdict 'failed install: refused'

run_step node "${ws_npm}" node,npm PLAN_MANAGER=cargo
expect_status 1
expect_calls
expect_line '::error::the plan named no known package manager ❌'
verdict 'unknown package manager: refused'

# The version reaches a single-line output record.
run_step node "${ws_npm}" node,npm PLAN_MANAGER=npm \
    PLAN_LOCKFILE=package-lock.json FAKE_NODE_VERSION=$'v22.11.0\ninjected=1'
expect_status 0
expect_outputs version=v22.11.0
grep -q '^injected' "${workdir}/case/output" &&
    check 'a second line of node output reached GITHUB_OUTPUT'
verdict 'multi-line node --version: first line only'

# shellcheck disable=SC2016 # the literal, unexpanded, is the point
for bad in '$(id)' '22.11.0' 'v22|x' ''; do
    run_step node "${ws_npm}" node,npm PLAN_MANAGER=npm \
        PLAN_LOCKFILE=package-lock.json FAKE_NODE_VERSION="${bad}"
    expect_status 1
    expect_line '::error::node --version printed something other than a version ❌'
    expect_calls
    verdict "unacceptable node --version refused: '${bad}'"
done

# --- Plan and prepare together ---------------------------------------

project package.json='{"packageManager": "pnpm@9.15.0"}' \
    pnpm-lock.yaml="${lock_pnpm}" .nvmrc='22'
ws_chain="${ws}"
run_chain "${ws}" node,corepack
expect_status 0
expect_outputs version=v22.11.0 prepared=true
expect_calls "${ws_chain}|0|0|corepack pnpm install --frozen-lockfile --prod=false --ignore-scripts"
expect_summary "| Node.js | \`v22.11.0\` (from .nvmrc: 22) |"
verdict 'chained: pnpm project pinned by .nvmrc'

run_chain "${ws_nolock}" node,npm
expect_status 0
expect_outputs prepared=false
expect_calls
expect_summary '- Dependencies not installed: no lockfile is tracked beside package.json; commit the one your package manager writes'
verdict 'chained: no lockfile, not prepared'

run_chain "${ws_npm}" node,npm INPUT_NODE_INSTALL_SCRIPTS='true'
expect_status 0
expect_calls "${ws_npm}|0|0|npm ci --no-audit --no-fund --include=dev"
verdict 'chained: npm with scripts on'

# --- Result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "${passed}" "${failed}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi
