<!--
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# ⛔️ Standalone Linting Action

This action runs linting checks as a standalone step, which is helpful
for tools that do not run well (or cannot run) under the GitHub marketplace
pre-commit.ci application.

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
      - uses: lfreleng-actions/standalone-linting-action@main
```

## Inputs

<!-- markdownlint-disable MD013 -->

| Variable Name    | Required | Description                                                | Default |
| ---------------- | -------- | ---------------------------------------------------------- | --------|
| config_url       | False    | Download location for pre-commit configuration             |         |
| dependencies_url | False    | Download location for supplementary Python dependencies    | None    |
| branch_name      | False    | Checkout this new Git branch before running linting checks | None    |
| path_prefix      | False    | Directory location containing project code                 | .       |
| no_checkout      | False    | Don't perform a checkout of the local repository           | false   |
| python-version   | False    | Python version used to run linting tools                   | 3.12    |

Caution: dash NOT underscore in python-version input/name

(This maintains alignment with other common actions, e.g. actions/setup-python)

<!-- markdownlint-enable MD013 -->
