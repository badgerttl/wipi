#!/usr/bin/env bash
set -Eeuo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wipi=${project_root}/wipi
installer=${project_root}/install.sh
temporary=$(mktemp -d)
trap 'rm -rf "${temporary}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1 needle=$2
  grep -Fq -- "${needle}" <<<"${haystack}" ||
    fail "expected output to contain: ${needle}"
}

assert_not_contains() {
  local haystack=$1 needle=$2
  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    fail "expected output not to contain: ${needle}"
  fi
}

expect_validation_failure() {
  local assignment=$1 expected=$2
  local output
  if output=$(
    WIPI_SOURCE_ONLY=1 bash -c "
      source '${wipi}'
      set_defaults
      WIPI_PASSWORD=validpass
      ${assignment}
      validate_logical_settings
    " 2>&1
  ); then
    fail "validation unexpectedly accepted: ${assignment}"
  fi
  assert_contains "${output}" "${expected}"
}

bash -n "${installer}"
bash -n "${wipi}"
"${wipi}" help >/dev/null

expect_validation_failure 'WIPI_INTERFACE="bad interface"' "invalid interface"
expect_validation_failure 'WIPI_SSID=""' "SSID must contain"
expect_validation_failure 'WIPI_PASSWORD="short"' "password must contain"
expect_validation_failure 'WIPI_ADDRESS="10.42.0.1/33"' "supports /24"
expect_validation_failure 'WIPI_COUNTRY="USA"' "two-letter"
expect_validation_failure 'WIPI_BAND="5"; WIPI_CHANNEL="52"' "36, 40, 44, or 48"
expect_validation_failure 'WIPI_UPSTREAM_INTERFACE="bad interface"' "invalid interface"

isolated_dns=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_PASSWORD=validpass
    validate_logical_settings
    render_dnsmasq_config
  "
)
assert_contains "${isolated_dns}" "interface=wlan0"
assert_contains "${isolated_dns}" "no-resolv"
assert_contains "${isolated_dns}" "address=/wipi.local/10.42.0.1"

isolated_firewall=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_PASSWORD=validpass
    validate_logical_settings
    render_firewall
  "
)
assert_contains "${isolated_firewall}" 'iifname "wlan0" drop'
assert_contains "${isolated_firewall}" 'oifname "wlan0" drop'
assert_not_contains "${isolated_firewall}" "masquerade"
assert_not_contains "${isolated_firewall}" "wipi_nat"

routed_firewall=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_PASSWORD=validpass
    WIPI_MODE=routed
    WIPI_UPSTREAM_INTERFACE=eth0
    validate_logical_settings
    render_firewall
  "
)
assert_contains "${routed_firewall}" 'iifname "wlan0" oifname "eth0" accept'
assert_contains "${routed_firewall}" 'iifname "wlan0" drop'
assert_contains "${routed_firewall}" "established,related"
assert_not_contains "${routed_firewall}" "masquerade"

malicious_root="${temporary}/malicious-root"
malicious_marker="${temporary}/configuration-was-executed"
mkdir -p "${malicious_root}/etc/wipi"
literal_command="\$(touch ${malicious_marker})"
printf 'WIPI_PASSWORD="%s"\n' "${literal_command}" \
  >"${malicious_root}/etc/wipi/wipi.conf"
WIPI_SOURCE_ONLY=1 WIPI_TEST_ROOT="${malicious_root}" bash -c "
  source '${wipi}'
  set_defaults
  load_config
  [[ \${WIPI_PASSWORD} == '\$(touch ${malicious_marker})' ]]
"
[[ ! -e ${malicious_marker} ]] ||
  fail "configuration contents were executed"

mkdir -p "${temporary}/bin" "${temporary}/root/run/systemd/system"
touch "${temporary}/nm-state" "${temporary}/commands.log"

cat >"${temporary}/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'nmcli %s\n' "$*" >>"${MOCK_LOG}"
if [[ $* == "--terse --fields NAME connection show" ]]; then
  [[ -r ${MOCK_NM_STATE} ]] && cat "${MOCK_NM_STATE}"
elif [[ $* == "connection add "* ]]; then
  grep -Fxq wipi "${MOCK_NM_STATE}" 2>/dev/null ||
    printf 'wipi\n' >>"${MOCK_NM_STATE}"
elif [[ $* == "connection delete wipi" ]]; then
  : >"${MOCK_NM_STATE}"
elif [[ $* == "--terse --fields NAME connection show --active" ]]; then
  [[ -r ${MOCK_NM_STATE} ]] && cat "${MOCK_NM_STATE}"
elif [[ $* == "--escape no -g connection.type connection show wipi" ]]; then
  printf '802-11-wireless\n'
fi
EOF

cat >"${temporary}/bin/iw" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'iw %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "dev wlan0 info")
    printf 'Interface wlan0\n\twiphy 0\n'
    ;;
  "phy phy0 info")
    cat <<'CAPABILITIES'
Supported interface modes:
	 * managed
	 * AP
Band 1:
	Frequencies:
		* 2437 MHz [6] (20.0 dBm)
Band 2:
	Frequencies:
		* 5180 MHz [36] (20.0 dBm)
CAPABILITIES
    ;;
  "reg set "*|"dev wlan0 set power_save off"|"dev wlan0 station dump")
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${temporary}/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'ip %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "link show dev wlan0"|"link show dev eth0")
    ;;
  "-4 route show default")
    printf 'default via 192.0.2.1 dev eth0\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${temporary}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'systemctl %s\n' "$*" >>"${MOCK_LOG}"
exit 0
EOF

cat >"${temporary}/bin/nft" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'nft %s\n' "$*" >>"${MOCK_LOG}"
if [[ ${1:-} == "-f" ]]; then
  cat >>"${MOCK_LOG}"
fi
EOF

cat >"${temporary}/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'sysctl %s\n' "$*" >>"${MOCK_LOG}"
if [[ ${1:-} == "-n" ]]; then
  printf '0\n'
fi
EOF

for command in rfkill dnsmasq; do
  cat >"${temporary}/bin/${command}" <<EOF
#!/usr/bin/env bash
printf '${command} %s\\n' "\$*" >>"\${MOCK_LOG}"
EOF
done
chmod +x "${temporary}/bin/"*

mock_env=(
  "PATH=${temporary}/bin:${PATH}"
  "MOCK_LOG=${temporary}/commands.log"
  "MOCK_NM_STATE=${temporary}/nm-state"
  "WIPI_TEST_MODE=1"
  "WIPI_TEST_ROOT=${temporary}/root"
)

env "${mock_env[@]}" "${wipi}" install \
  --password validpass --mode isolated >/dev/null
env "${mock_env[@]}" "${wipi}" install \
  --mode isolated >/dev/null

profile_add_count=$(grep -c '^nmcli connection add ' "${temporary}/commands.log")
[[ ${profile_add_count} == "1" ]] ||
  fail "repeated install created ${profile_add_count} NetworkManager profiles"
[[ -f ${temporary}/root/etc/systemd/system/wipi.service ]] ||
  fail "install did not create the systemd unit"
[[ -x ${temporary}/root/usr/local/bin/wipi ]] ||
  fail "install did not create /usr/local/bin/wipi"
config_mode=$(
  stat -c '%a' "${temporary}/root/etc/wipi/wipi.conf" 2>/dev/null ||
    stat -f '%Lp' "${temporary}/root/etc/wipi/wipi.conf"
)
[[ ${config_mode} == "600" ]] ||
  fail "configuration permissions are not 0600"

profile_log=$(<"${temporary}/commands.log")
assert_contains "${profile_log}" "ipv4.method manual"
assert_contains "${profile_log}" "wifi-sec.pmf 1"
assert_contains "${profile_log}" "802-11-wireless.powersave 2"
assert_contains "${profile_log}" "802-11-wireless.cloned-mac-address permanent"
assert_not_contains "${profile_log}" "wlan1"

hardware_error=$(
  WIPI_SOURCE_ONLY=1 WIPI_TEST_MODE=1 \
    PATH="${temporary}/bin:${PATH}" \
    MOCK_LOG="${temporary}/commands.log" \
    MOCK_NM_STATE="${temporary}/nm-state" \
    bash -c "
      source '${wipi}'
      set_defaults
      WIPI_PASSWORD=validpass
      WIPI_INTERFACE=wlan1
      validate_settings
    " 2>&1
) && fail "hardware validation unexpectedly accepted wlan1"
assert_contains "${hardware_error}" "does not exist"

upstream_error=$(
  WIPI_SOURCE_ONLY=1 WIPI_TEST_MODE=1 \
    PATH="${temporary}/bin:${PATH}" \
    MOCK_LOG="${temporary}/commands.log" \
    MOCK_NM_STATE="${temporary}/nm-state" \
    bash -c "
      source '${wipi}'
      set_defaults
      WIPI_PASSWORD=validpass
      WIPI_MODE=routed
      WIPI_UPSTREAM_INTERFACE=eno9
      validate_settings
    " 2>&1
) && fail "hardware validation unexpectedly accepted missing upstream"
assert_contains "${upstream_error}" "does not exist"

env "${mock_env[@]}" "${wipi}" configure \
  --mode routed --upstream-interface eth0 >/dev/null
profile_log=$(<"${temporary}/commands.log")
assert_contains "${profile_log}" "ipv4.method shared"

dnsmasq_marker="${temporary}/dnsmasq-started"
WIPI_SOURCE_ONLY=1 WIPI_TEST_MODE=1 \
  WIPI_TEST_ROOT="${temporary}/root" \
  PATH="${temporary}/bin:${PATH}" \
  MOCK_LOG="${temporary}/commands.log" \
  MOCK_NM_STATE="${temporary}/nm-state" \
  DNSMASQ_MARKER="${dnsmasq_marker}" \
  bash -c "
    source '${wipi}'
    set_defaults() {
      WIPI_INTERFACE=wlan0
      WIPI_SSID=wipi
      WIPI_PASSWORD=validpass
      WIPI_ADDRESS=10.42.0.1/24
      WIPI_HOSTNAME=wipi.local
      WIPI_COUNTRY=US
      WIPI_BAND=2.4
      WIPI_CHANNEL=6
      WIPI_MODE=routed
      WIPI_UPSTREAM_INTERFACE=
    }
    load_config() { :; }
    connection_exists() { return 0; }
    configure_country() { :; }
    stop_dnsmasq() { :; }
    remove_firewall() { :; }
    enable_ip_forwarding() { :; }
    apply_firewall() { :; }
    activate_profile() { :; }
    start_dnsmasq() { : >\"\${DNSMASQ_MARKER}\"; }
    service_start
  "
[[ ! -e ${dnsmasq_marker} ]] ||
  fail "routed mode launched isolated dnsmasq"

env "${mock_env[@]}" "${wipi}" mode isolated >/dev/null
env "${mock_env[@]}" "${wipi}" mode routed >/dev/null
env "${mock_env[@]}" "${wipi}" mode isolated >/dev/null
assert_contains "$(<"${temporary}/root/etc/wipi/wipi.conf")" 'WIPI_MODE="isolated"'

env "${mock_env[@]}" "${wipi}" start
env "${mock_env[@]}" "${wipi}" start
env "${mock_env[@]}" "${wipi}" stop
env "${mock_env[@]}" "${wipi}" stop
start_count=$(grep -c '^systemctl start wipi.service$' "${temporary}/commands.log")
stop_count=$(grep -c '^systemctl stop wipi.service$' "${temporary}/commands.log")
[[ ${start_count} == "2" && ${stop_count} == "2" ]] ||
  fail "repeated start/stop did not use idempotent systemd operations"

secret_status=$(
  env "${mock_env[@]}" "${wipi}" status
)
assert_not_contains "${secret_status}" "validpass"

WIPI_SOURCE_ONLY=1 WIPI_TEST_MODE=1 \
  WIPI_TEST_ROOT="${temporary}/root" \
  PATH="${temporary}/bin:${PATH}" \
  MOCK_LOG="${temporary}/commands.log" \
  MOCK_NM_STATE="${temporary}/nm-state" \
  bash -c "
    source '${wipi}'
    set_defaults
    load_config
    WIPI_MODE=isolated
    apply_firewall
    apply_firewall
  "

firewall_log=$(<"${temporary}/commands.log")
assert_not_contains "${firewall_log}" "flush ruleset"
assert_not_contains "${firewall_log}" "delete table inet filter"
assert_contains "${firewall_log}" "delete table inet wipi_filter"

env "${mock_env[@]}" "${wipi}" uninstall --keep-config >/dev/null
[[ -f ${temporary}/root/etc/wipi/wipi.conf ]] ||
  fail "uninstall --keep-config removed the saved configuration"
[[ ! -e ${temporary}/root/usr/local/bin/wipi ]] ||
  fail "uninstall left the installed command behind"
[[ ! -e ${temporary}/root/etc/systemd/system/wipi.service ]] ||
  fail "uninstall left the systemd unit behind"
assert_not_contains "$(<"${temporary}/commands.log")" "flush ruleset"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${installer}" "${wipi}" "$0"
else
  printf 'ShellCheck not installed; skipped static lint.\n'
fi

printf 'All checks passed.\n'
