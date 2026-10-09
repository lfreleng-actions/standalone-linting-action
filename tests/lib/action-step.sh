# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
#
# Shared by the suites under tests/ that run ONE step of action.yaml
# on its own. Sourced, never run.
#
# The step is EXTRACTED from action.yaml, never copied, so a suite
# exercises the code the action runs. Its environment is the step's
# own 'env' block with each input at its declared default, and each
# earlier step's output empty, for a suite to set as a case needs. A
# missing step, or an env entry that is neither a plain input nor a
# plain step-output reference, fails the extraction rather than
# letting a suite test nothing.

# A suite run as a hook inside 'git commit' inherits GIT_INDEX_FILE
# and git's other repository-local variables. In a linked worktree
# they hold absolute paths, so git in a suite's fixture repository
# would stage into THIS repository's index. Clear every one.
while IFS= read -r git_local_var; do
    unset "${git_local_var}"
done < <(git rev-parse --local-env-vars)
unset git_local_var

# Sets PY_RUN to an interpreter that can import yaml.
#
# Prefer one that already has PyYAML. The prek hook environment
# supplies it, and pre-commit.ci's sandbox has no network to fetch it
# with, so asking uv first would fail there. uv is the fallback for a
# direct invocation.
#
# Finding neither is a FAILURE, never a skip: a skip would report
# success having checked nothing.
#
# '-I' because the extractor arrives on stdin, which puts the current
# directory on sys.path. '--no-config' because uv otherwise discovers
# a 'uv.toml' in the checkout, which could redirect the index PyYAML
# installs from.
action_step_python() {
    if python3 -I -c 'import yaml' > /dev/null 2>&1; then
        PY_RUN=(python3 -I)
    elif command -v uv > /dev/null 2>&1; then
        PY_RUN=(uv run --no-project --no-config --with pyyaml==6.0.2
            python -I)
    else
        echo 'ERROR: no interpreter with PyYAML available' >&2
        echo '       Install uv (https://docs.astral.sh/uv/), or run' >&2
        echo '       this through the prek hook, which supplies PyYAML.' >&2
        return 1
    fi
}

# action_step_extract <action.yaml> <step id> <script out> <env out>
#
# Writes the step's 'run' script to <script out>, and its env block
# to <env out> as NUL-terminated NAME=DEFAULT records.
action_step_extract() {
    "${PY_RUN[@]}" - "$1" "$2" "$3" > "$4" <<'PYEOF'
import re
import sys

import yaml

action_path, step_id, script_path = sys.argv[1:4]
with open(action_path, encoding='utf-8') as handle:
    action = yaml.safe_load(handle)
inputs = action.get('inputs') or {}
steps = [
    step
    for step in (action.get('runs') or {}).get('steps') or []
    if isinstance(step, dict) and step.get('id') == step_id
]
if len(steps) != 1:
    sys.exit(f"expected one step with id '{step_id}', found {len(steps)}")
step = steps[0]
if step.get('shell') != 'bash' or not isinstance(step.get('run'), str):
    sys.exit(f"the '{step_id}' step is not a bash run step")
with open(script_path, 'w', encoding='utf-8') as handle:
    handle.write(step['run'])

# Each env entry must pass one input, or one output of an earlier
# step, straight through. Anything else needs a value this suite
# cannot supply, so refuse it rather than run the step with the
# variable unset. An output starts empty, as it is when the step that
# writes it skipped or wrote nothing.
reference = re.compile(r'\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}')
output = re.compile(
    r'\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.[A-Za-z0-9_-]+\s*\}\}'
)
all_steps = (action.get('runs') or {}).get('steps') or []
earlier = {
    other.get('id')
    for other in all_steps[: all_steps.index(step)]
    if isinstance(other, dict)
}
for name, value in (step.get('env') or {}).items():
    produced = output.fullmatch(str(value))
    if produced is not None and produced.group(1) in earlier:
        sys.stdout.write(f'{name}=\0')
        continue
    match = reference.fullmatch(str(value))
    if match is None or match.group(1) not in inputs:
        sys.exit(f'env {name} is not an input or step-output reference: '
                 f'{value!r}')
    default = (inputs[match.group(1)] or {}).get('default', '')
    if isinstance(default, bool):
        default = 'true' if default else 'false'
    # NUL-terminated, so a default may hold any character.
    sys.stdout.write(f'{name}={default}\0')
PYEOF
}
