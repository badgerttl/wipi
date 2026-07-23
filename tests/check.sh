#!/usr/bin/env bash
set -Eeuo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "${project_root}/install.sh"
bash -n "${project_root}/wipi"
"${project_root}/wipi" --help >/dev/null

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${project_root}/install.sh" "${project_root}/wipi"
fi

printf 'All checks passed.\n'
