#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Contract checks that the caller's job environment cannot choose the
# Python the action runs.
#
# An earlier step of the caller's job may set PATH, UV_PYTHON*,
# VIRTUAL_ENV, CONDA_PREFIX and the like through GITHUB_ENV or
# GITHUB_PATH, and a checkout may hold a .venv or a .python-version.
# action.yaml defends against that in three places, and this suite
# pins each one, so a later edit cannot reopen the route silently:
#
#   - the 'Set up uv' step refuses every interpreter lookup and keeps
#     the inputs that would export settings to later steps unset;
#   - the 'Install Python' step installs one uv-managed Python under
#     an empty environment and requires it in its own directory;
#   - every later uv or uvx call is by the absolute path setup-uv
#     reports, and names that interpreter with '--python "$PYTHON"'.
#
# The 'isolation-*' jobs in .github/workflows/testing.yaml plant bait
# and run the action for real; this suite fails before a push.
#
# Usage: bash tests/test-python-isolation.sh

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

status=0
"${PY_RUN[@]}" - "${action}" > "${workdir}/out" 2>&1 <<'PYEOF' || status=$?
import re
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    action = yaml.safe_load(handle)
steps = [
    step for step in (action.get('runs') or {}).get('steps') or []
    if isinstance(step, dict)
]
passed = 0
failed = 0


def check(label, problems):
    global passed, failed
    if problems:
        failed += 1
        print(f'FAIL: {label}')
        for problem in problems:
            print(f'      {problem}')
    else:
        passed += 1
        print(f'PASS: {label}')


def named(name):
    found = [step for step in steps if step.get('name') == name]
    return found[0] if len(found) == 1 else None


# --- Set up uv ---------------------------------------------------------

problems = []
setup = named('Set up uv')
if setup is None:
    problems.append("expected one 'Set up uv' step")
    setup = {}
if not str(setup.get('uses', '')).startswith('astral-sh/setup-uv@'):
    problems.append(f"it uses {setup.get('uses')!r}")
if setup.get('id') != 'setup-uv':
    problems.append(f"its id is {setup.get('id')!r}, not 'setup-uv'")
env = setup.get('env') or {}
wanted_env = {
    'UV_NO_CONFIG': '1',
    'UV_NO_PROJECT': '1',
    'UV_PYTHON_PREFERENCE': 'lookup-disabled',
    'UV_PYTHON_ARCH': '',
}
for name, value in wanted_env.items():
    if str(env.get(name)) != value:
        problems.append(f'env {name} is {env.get(name)!r}, not {value!r}')
install_dir = str(env.get('UV_PYTHON_INSTALL_DIR', ''))
if not install_dir.startswith('${{ runner.temp }}/'):
    problems.append(f'env UV_PYTHON_INSTALL_DIR is {install_dir!r}')
for name in ('UV_SYSTEM_PYTHON', 'UV_MANAGED_PYTHON', 'UV_PYTHON'):
    if name in env:
        problems.append(f'env sets {name}')
inputs = setup.get('with') or {}
if inputs.get('working-directory') != '${{ github.action_path }}':
    problems.append('working-directory is not the action directory')
if not str(inputs.get('tool-bin-dir', '')).startswith('${{ runner.temp }}/'):
    problems.append(f"tool-bin-dir is {inputs.get('tool-bin-dir')!r}")
if not re.fullmatch(r'\d+\.\d+\.\d+', str(inputs.get('version', ''))):
    problems.append(f"version is {inputs.get('version')!r}, not pinned")
for name in ('python-version', 'activate-environment'):
    if name in inputs:
        problems.append(f'with sets {name}')
check("'Set up uv' refuses lookups and exports nothing", problems)

# --- Install Python ----------------------------------------------------

problems = []
install = named('Install Python')
if install is None:
    problems.append("expected one 'Install Python' step")
    install = {}
if install.get('id') != 'python':
    problems.append(f"its id is {install.get('id')!r}, not 'python'")
env = install.get('env') or {}
if env.get('UV') != '${{ steps.setup-uv.outputs.uv-path }}':
    problems.append(f"env UV is {env.get('UV')!r}")
if env.get('INSTALL_DIR') != install_dir:
    problems.append("env INSTALL_DIR is not setup-uv's install directory")
script = str(install.get('run', ''))
for needle in ('/usr/bin/env -i "${clean[@]}" "$UV" python install',
               '/usr/bin/env -i "${clean[@]}" "$UV" python find',
               '--managed-python', '"$INSTALL_DIR"/*) ;;'):
    if needle not in script:
        problems.append(f'its script lacks {needle!r}')
check("'Install Python' installs one managed Python, env -i", problems)

# --- Every uv and uvx call ---------------------------------------------


def commands(script):
    """Logical command lines: comments dropped, backslash continuations
    and multi-line array definitions ('name=(' up to its ')') joined."""
    joined = []
    pending = ''
    in_array = False
    for raw in script.splitlines():
        line = raw.strip()
        if not pending and line.startswith('#'):
            continue
        pending = f'{pending} {line}' if pending else line
        if pending.endswith('\\'):
            pending = pending[:-1]
            continue
        if re.match(r'\w+=\(', pending):
            in_array = pending.count('(') > pending.count(')')
            if in_array:
                continue
        joined.append(pending)
        pending = ''
    if pending:
        joined.append(pending)
    return joined


bare = re.compile(r'(?:^|[;&|(`]|\$\()\s*(?:command\s+|exec\s+)?uvx?\s')
# "$UV" or "$UVX" where a command starts, after any VAR=value
# prefixes, or after env's arguments.
call = re.compile(
    r'(?:^|\$\(|\w=\(|[;&|]|"\$\{clean\[@\]\}")\s*'
    r'(?:\w+=(?:"[^"]*"|\S*)\s+)*"\$(UVX?)"(?=\s)'
)
problems = []
calls = 0
for step in steps:
    if 'run' not in step:
        continue
    name = step.get('name', step.get('id', '?'))
    for line in commands(str(step['run'])):
        if bare.search(line):
            problems.append(f'{name}: bare uv or uvx: {line[:100]}')
        if not call.search(line):
            continue
        calls += 1
        if step is install and '/usr/bin/env -i ' in line:
            continue
        if '--python "$PYTHON"' not in line:
            problems.append(f'{name}: no --python "$PYTHON": {line[:100]}')
        if '--cache-dir "$CACHE_DIR"' not in line:
            problems.append(f'{name}: no --cache-dir: {line[:100]}')
        env = step.get('env') or {}
        for var in call.findall(line):
            want = ('${{ steps.setup-uv.outputs.%s-path }}'
                    % var.lower())
            if env.get(var) != want:
                problems.append(f'{name}: env {var} is {env.get(var)!r}')
        if 'PYTHON' in line and step is not install:
            if (env.get('PYTHON')
                    != '${{ steps.python.outputs.path }}'):
                problems.append(f"{name}: env PYTHON is "
                                f"{env.get('PYTHON')!r}")
if calls < 8:
    problems.append(f'only {calls} uv/uvx calls found; the parser drifted')
check('every uv and uvx call names the installed Python', problems)

print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PYEOF
cat "${workdir}/out"
exit "${status}"
