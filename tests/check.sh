#!/usr/bin/env bash
set -Eeuo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer=${project_root}/install.sh

require_installer_setting() {
  local setting=$1

  if ! grep -Fq "${setting}" "${installer}"; then
    printf 'Missing required installer setting: %s\n' "${setting}" >&2
    return 1
  fi
}

bash -n "${installer}"
bash -n "${project_root}/wipi"
"${project_root}/wipi" --help >/dev/null

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${installer}" "${project_root}/wipi"
fi

require_installer_setting 'wifi-sec.key-mgmt wpa-psk'
require_installer_setting 'wifi-sec.proto rsn'
require_installer_setting 'wifi-sec.pairwise ccmp'
require_installer_setting 'wifi-sec.group ccmp'
require_installer_setting 'wifi-sec.pmf 1'
require_installer_setting '802-11-wireless.powersave 2'

printf 'All checks passed.\n'
