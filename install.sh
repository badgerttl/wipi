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

configured_wifi_backend() {
  local backend_config=/etc/NetworkManager/conf.d/99-wipi-backend.conf

  if [[ -r ${backend_config} ]] &&
    grep -Eq '^[[:space:]]*wifi\.backend[[:space:]]*=[[:space:]]*iwd[[:space:]]*$' "${backend_config}"; then
    printf 'iwd\n'
  else
    printf 'wpa_supplicant\n'
  fi
}

install_apt_package() {
  local package=$1

  if dpkg-query -W -f='${Status}' "${package}" 2>/dev/null |
    grep -Fq 'install ok installed'; then
    return
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${package}"
}

configure_wifi_backend() {
  local config_dir=/etc/NetworkManager/conf.d
  local config_file=${config_dir}/99-wipi-backend.conf

  case ${WIPI_BACKEND} in
    iwd)
      install_apt_package network-manager-iwd
      install -d -m755 "${config_dir}"
      {
        printf '[device-wipi-backend]\n'
        printf 'wifi.backend=iwd\n'
        printf 'wifi.iwd.autoconnect=false\n'
      } >"${config_file}"
      systemctl enable --now iwd
      ;;
    wpa_supplicant)
      if ! command -v wpa_supplicant >/dev/null 2>&1; then
        install_apt_package wpasupplicant
      fi
      systemctl disable --now iwd 2>/dev/null || true
      install -d -m755 "${config_dir}"
      {
        printf '[device-wipi-backend]\n'
        printf 'wifi.backend=wpa_supplicant\n'
      } >"${config_file}"
      ;;
    *)
      die "WIPI_BACKEND must be wpa_supplicant or iwd"
      ;;
  esac

  log "using NetworkManager Wi-Fi backend '${WIPI_BACKEND}'"
  systemctl restart NetworkManager
  nm-online --quiet --timeout 15 2>/dev/null || true
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

load_existing_settings() {
  if ! nmcli --terse --fields NAME connection show |
    grep -Fxq "${CONNECTION_NAME}"; then
    return
  fi

  local saved_ssid saved_password saved_address saved_channel saved_band
  saved_ssid=$(nmcli --escape no -g 802-11-wireless.ssid connection show "${CONNECTION_NAME}" 2>/dev/null || true)
  saved_password=$(nmcli --escape no --show-secrets -g 802-11-wireless-security.psk connection show "${CONNECTION_NAME}" 2>/dev/null || true)
  saved_address=$(nmcli --escape no -g ipv4.addresses connection show "${CONNECTION_NAME}" 2>/dev/null || true)
  saved_channel=$(nmcli --escape no -g 802-11-wireless.channel connection show "${CONNECTION_NAME}" 2>/dev/null || true)
  saved_band=$(nmcli --escape no -g 802-11-wireless.band connection show "${CONNECTION_NAME}" 2>/dev/null || true)

  WIPI_SSID=${WIPI_SSID:-${saved_ssid}}
  WIPI_PASSWORD=${WIPI_PASSWORD:-${saved_password}}
  WIPI_ADDRESS=${WIPI_ADDRESS:-${saved_address}}
  WIPI_CHANNEL=${WIPI_CHANNEL:-${saved_channel}}
  WIPI_BAND=${WIPI_BAND:-${saved_band}}
}

normalize_band() {
  case ${WIPI_BAND,,} in
    2.4|2.4ghz|bg)
      WIPI_BAND="2.4"
      NM_BAND="bg"
      ;;
    5|5ghz|a)
      WIPI_BAND="5"
      NM_BAND="a"
      ;;
    *)
      die "WIPI_BAND must be 2.4 or 5"
      ;;
  esac
}

validate_settings() {
  [[ ${#WIPI_SSID} -ge 1 && ${#WIPI_SSID} -le 32 ]] ||
    die "WIPI_SSID must contain 1 to 32 characters"
  [[ ${#WIPI_PASSWORD} -ge 8 && ${#WIPI_PASSWORD} -le 63 ]] ||
    die "WIPI_PASSWORD must contain 8 to 63 characters"
  [[ ${WIPI_CHANNEL} =~ ^[0-9]+$ ]] ||
    die "WIPI_CHANNEL must be a number"

  if [[ ${WIPI_BAND} == "2.4" ]]; then
    ((WIPI_CHANNEL >= 1 && WIPI_CHANNEL <= 13)) ||
      die "2.4 GHz WIPI_CHANNEL must be between 1 and 13"
  else
    case ${WIPI_CHANNEL} in
      36|40|44|48) ;;
      *) die "5 GHz WIPI_CHANNEL must be 36, 40, 44, or 48" ;;
    esac
  fi
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
  local five_ghz_support

  systemctl enable --now NetworkManager
  rfkill unblock wifi 2>/dev/null || true
  nmcli radio wifi on
  nmcli device set "${interface}" managed yes

  if [[ ${WIPI_BAND} == "5" ]]; then
    five_ghz_support=$(nmcli -g WIFI-PROPERTIES.5GHZ device show "${interface}" 2>/dev/null || true)
    if [[ ${five_ghz_support} == "no" ]]; then
      die "'${interface}' reports that it does not support 5 GHz"
    elif [[ ${five_ghz_support} != "yes" ]]; then
      log "warning: ${WIPI_BACKEND} did not report 5 GHz capability; attempting activation"
    fi
  fi

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
    802-11-wireless.band "${NM_BAND}" \
    802-11-wireless.channel "${WIPI_CHANNEL}" \
    802-11-wireless.cloned-mac-address permanent \
    802-11-wireless.powersave 2 \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.proto rsn \
    wifi-sec.pairwise ccmp \
    wifi-sec.group ccmp \
    wifi-sec.pmf 1 \
    wifi-sec.psk "${WIPI_PASSWORD}" \
    ipv4.method shared \
    ipv4.addresses "${WIPI_ADDRESS}" \
    ipv6.method disabled

  # NetworkManager 1.50+ supports explicit AP channel width. Trixie has it;
  # Bookworm does not, so detect the field instead of comparing versions.
  if nmcli --fields 802-11-wireless.channel-width connection show "${CONNECTION_NAME}" \
    >/dev/null 2>&1; then
    nmcli connection modify "${CONNECTION_NAME}" \
      802-11-wireless.channel-width 20
  fi

  if ! nmcli connection up "${CONNECTION_NAME}"; then
    if [[ ${WIPI_BACKEND} == "iwd" ]]; then
      log "iwd could not activate AP mode; restoring the wpa_supplicant backend"
      WIPI_BACKEND=wpa_supplicant
      configure_wifi_backend
      if ! nmcli connection up "${CONNECTION_NAME}"; then
        die "the access point profile was created, but could not be started; run 'sudo wipi diagnose' for details"
      fi
    else
      die "the access point profile was created, but could not be started; run 'sudo wipi diagnose' for details"
    fi
  fi

  # Some brcmfmac/iw combinations report power saving independently of
  # NetworkManager. Reinforce the profile setting after the interface is up.
  if command -v iw >/dev/null 2>&1; then
    iw dev "${interface}" set power_save off 2>/dev/null || true
  fi
}

install_cli() {
  install -Dm755 "$(dirname "${BASH_SOURCE[0]}")/wipi" /usr/local/sbin/wipi
}

main() {
  require_root
  require_linux

  local band_was_set=${WIPI_BAND+x}
  local channel_was_set=${WIPI_CHANNEL+x}

  install_network_manager
  load_existing_settings

  WIPI_SSID=${WIPI_SSID:-wipi}
  WIPI_PASSWORD=${WIPI_PASSWORD:-$(generate_password)}
  WIPI_ADDRESS=${WIPI_ADDRESS:-${DEFAULT_ADDRESS}}
  WIPI_BACKEND=${WIPI_BACKEND:-$(configured_wifi_backend)}
  WIPI_BAND=${WIPI_BAND:-2.4}
  normalize_band

  # When switching bands without an explicit channel, choose a safe,
  # non-DFS default instead of reusing the other band's channel.
  if [[ -n ${band_was_set} && -z ${channel_was_set} ]]; then
    WIPI_CHANNEL=
  fi
  if [[ ${WIPI_BAND} == "5" ]]; then
    WIPI_CHANNEL=${WIPI_CHANNEL:-36}
  else
    WIPI_CHANNEL=${WIPI_CHANNEL:-6}
  fi
  validate_settings

  configure_country
  configure_wifi_backend

  local interface
  interface=$(find_wifi_interface)
  configure_access_point "${interface}"
  install_cli

  local host_address=${WIPI_ADDRESS%/*}
  printf '\n'
  log "access point is ready"
  printf '  SSID:       %s\n' "${WIPI_SSID}"
  printf '  Password:   %s\n' "${WIPI_PASSWORD}"
  printf '  Backend:    %s\n' "${WIPI_BACKEND}"
  printf '  Radio:      %s GHz, channel %s\n' "${WIPI_BAND}" "${WIPI_CHANNEL}"
  printf '  Pi address: %s\n' "${host_address}"
  printf '  Status:     sudo wipi status\n'
  printf '\nServices must listen on 0.0.0.0 (or %s) to accept Wi-Fi clients.\n' "${host_address}"
}

main "$@"
