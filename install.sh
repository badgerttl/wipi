#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONNECTION_NAME="wipi-ap"
readonly DEFAULT_ADDRESS="10.42.0.1/24"

log() {
  printf '[wipi] %s\n' "$*"
}

die() {
  printf '[wipi] error: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "run this installer with sudo"
}

require_linux() {
  [[ $(uname -s) == "Linux" ]] || die "this installer only supports Linux"
  [[ -r /etc/os-release ]] || die "cannot identify this Linux distribution"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == "raspbian" || ${ID:-} == "debian" ]] ||
    die "supported systems are Raspberry Pi OS and Debian"
}

install_network_manager() {
  if command -v nmcli >/dev/null 2>&1; then
    return
  fi

  command -v apt-get >/dev/null 2>&1 ||
    die "NetworkManager is required and apt-get is unavailable"

  log "installing NetworkManager"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager
}

find_wifi_interface() {
  local requested=${WIPI_INTERFACE:-}
  local interface

  if [[ -n ${requested} ]]; then
    [[ -d "/sys/class/net/${requested}/wireless" ]] ||
      die "'${requested}' is not a wireless interface"
    printf '%s\n' "${requested}"
    return
  fi

  for interface in /sys/class/net/*; do
    if [[ -d "${interface}/wireless" ]]; then
      basename "${interface}"
      return
    fi
  done

  die "no wireless interface found"
}

generate_password() {
  local generated
  generated=$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')
  printf 'wipi-%s\n' "${generated:0:12}"
}

validate_settings() {
  [[ ${#WIPI_SSID} -ge 1 && ${#WIPI_SSID} -le 32 ]] ||
    die "WIPI_SSID must contain 1 to 32 characters"
  [[ ${#WIPI_PASSWORD} -ge 8 && ${#WIPI_PASSWORD} -le 63 ]] ||
    die "WIPI_PASSWORD must contain 8 to 63 characters"
  [[ ${WIPI_CHANNEL} =~ ^[0-9]+$ ]] ||
    die "WIPI_CHANNEL must be a number"
  ((WIPI_CHANNEL >= 1 && WIPI_CHANNEL <= 13)) ||
    die "WIPI_CHANNEL must be between 1 and 13"
}

configure_country() {
  if [[ -z ${WIPI_COUNTRY:-} ]]; then
    return
  fi

  [[ ${WIPI_COUNTRY} =~ ^[A-Za-z]{2}$ ]] ||
    die "WIPI_COUNTRY must be a two-letter country code"
  WIPI_COUNTRY=${WIPI_COUNTRY^^}

  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "${WIPI_COUNTRY}"
  elif command -v iw >/dev/null 2>&1; then
    iw reg set "${WIPI_COUNTRY}"
  else
    log "warning: could not set Wi-Fi country to ${WIPI_COUNTRY}"
  fi
}

configure_access_point() {
  local interface=$1

  systemctl enable --now NetworkManager
  rfkill unblock wifi 2>/dev/null || true
  nmcli radio wifi on
  nmcli device set "${interface}" managed yes

  if nmcli --terse --fields NAME connection show |
    grep -Fxq "${CONNECTION_NAME}"; then
    log "replacing the existing ${CONNECTION_NAME} profile"
    nmcli connection delete "${CONNECTION_NAME}" >/dev/null
  fi

  log "creating access point '${WIPI_SSID}' on ${interface}"
  nmcli connection add \
    type wifi \
    ifname "${interface}" \
    con-name "${CONNECTION_NAME}" \
    ssid "${WIPI_SSID}" >/dev/null

  nmcli connection modify "${CONNECTION_NAME}" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel "${WIPI_CHANNEL}" \
    802-11-wireless.powersave 2 \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "${WIPI_PASSWORD}" \
    ipv4.method shared \
    ipv4.addresses "${WIPI_ADDRESS}" \
    ipv6.method disabled

  if ! nmcli connection up "${CONNECTION_NAME}"; then
    die "the access point profile was created, but could not be started; run 'sudo wipi status' for details"
  fi
}

install_cli() {
  install -Dm755 "$(dirname "${BASH_SOURCE[0]}")/wipi" /usr/local/sbin/wipi
}

main() {
  require_root
  require_linux

  WIPI_SSID=${WIPI_SSID:-wipi}
  WIPI_PASSWORD=${WIPI_PASSWORD:-$(generate_password)}
  WIPI_ADDRESS=${WIPI_ADDRESS:-${DEFAULT_ADDRESS}}
  WIPI_CHANNEL=${WIPI_CHANNEL:-6}
  validate_settings

  install_network_manager
  configure_country

  local interface
  interface=$(find_wifi_interface)
  configure_access_point "${interface}"
  install_cli

  local host_address=${WIPI_ADDRESS%/*}
  printf '\n'
  log "access point is ready"
  printf '  SSID:       %s\n' "${WIPI_SSID}"
  printf '  Password:   %s\n' "${WIPI_PASSWORD}"
  printf '  Pi address: %s\n' "${host_address}"
  printf '  Status:     sudo wipi status\n'
  printf '\nServices must listen on 0.0.0.0 (or %s) to accept Wi-Fi clients.\n' "${host_address}"
}

main "$@"
