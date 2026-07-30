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

assert_file_contains() {
  local file=$1 text=$2
  grep -Fq -- "${text}" "${file}" ||
    fail "expected ${file} to contain: ${text}"
}

assert_status_value() {
  local output=$1 label=$2 value=$3
  if ! grep -Eq "^${label}:[[:space:]]+${value}$" <<<"${output}"; then
    printf '%s\n' "${output}" >&2
    fail "expected status ${label}: ${value}"
  fi
}

expect_logical_failure() {
  local assignment=$1 expected=$2 output
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

expect_logical_failure 'WIPI_INTERFACE="bad interface"' "invalid interface"
expect_logical_failure 'WIPI_SSID=""' "SSID must contain"
expect_logical_failure 'WIPI_PASSWORD="short"' "password must contain"
expect_logical_failure 'WIPI_ADDRESS="10.10.0.1/33"' "supports /24"
expect_logical_failure 'WIPI_COUNTRY="USA"' "two-letter"
expect_logical_failure \
  'WIPI_BAND="5"; WIPI_CHANNEL="52"' "36, 40, 44, or 48"
expect_logical_failure \
  'WIPI_UPSTREAM_INTERFACE="bad interface"' "invalid interface"
expect_logical_failure \
  'WIPI_UPSTREAM_INTERFACE="wlan0"' "cannot be the AP interface"

default_values=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_PASSWORD=validpass
    validate_logical_settings
    dhcp_values
    printf '%s|%s|%s|%s\n' \
      \"\${WIPI_ADDRESS}\" \"\${AP_SUBNET}\" \
      \"\${DHCP_START}\" \"\${DHCP_END}\"
  "
)
[[ ${default_values} == \
  "10.10.0.1/24|10.10.0.0/24|10.10.0.10|10.10.0.100" ]] ||
  fail "fresh defaults or DHCP range are incorrect: ${default_values}"

migration_values=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_ADDRESS=\${OLD_DEFAULT_ADDRESS}
    migrate_old_default_address >/dev/null
    printf '%s|%s\n' \"\${WIPI_ADDRESS}\" \"\${CONFIG_MIGRATED}\"
  "
)
[[ ${migration_values} == "10.10.0.1/24|1" ]] ||
  fail "former default address was not migrated"

custom_values=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_ADDRESS=10.77.0.1/24
    migrate_old_default_address
    printf '%s|%s\n' \"\${WIPI_ADDRESS}\" \"\${CONFIG_MIGRATED}\"
  "
)
[[ ${custom_values} == "10.77.0.1/24|0" ]] ||
  fail "custom address was changed during migration"

stored_migration_root="${temporary}/stored-migration"
WIPI_SOURCE_ONLY=1 WIPI_TEST_ROOT="${stored_migration_root}" bash -c "
  source '${wipi}'
  set_defaults
  WIPI_PASSWORD=validpass
  WIPI_ADDRESS=10.42.0.1/24
  validate_logical_settings
  write_config
"
stored_migration_output=$(
  WIPI_SOURCE_ONLY=1 WIPI_TEST_ROOT="${stored_migration_root}" bash -c "
    source '${wipi}'
    set_defaults
    load_config
    migrate_old_default_address
    validate_logical_settings
    write_config
    printf '%s\n' \"\${WIPI_ADDRESS}\"
  "
)
assert_contains "${stored_migration_output}" "migrating the former default"
assert_file_contains "${stored_migration_root}/etc/wipi/wipi.conf" \
  'WIPI_ADDRESS="10.10.0.1/24"'

stored_custom_root="${temporary}/stored-custom"
WIPI_SOURCE_ONLY=1 WIPI_TEST_ROOT="${stored_custom_root}" bash -c "
  source '${wipi}'
  set_defaults
  WIPI_PASSWORD=validpass
  WIPI_ADDRESS=10.77.0.1/24
  validate_logical_settings
  write_config
  set_defaults
  load_config
  migrate_old_default_address
  write_config
"
assert_file_contains "${stored_custom_root}/etc/wipi/wipi.conf" \
  'WIPI_ADDRESS="10.77.0.1/24"'

isolated_dns=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_PASSWORD=validpass
    validate_logical_settings
    render_dnsmasq_config
  "
)
assert_contains "${isolated_dns}" \
  "dhcp-range=10.10.0.10,10.10.0.100,255.255.255.0,12h"
assert_contains "${isolated_dns}" "address=/wipi.local/10.10.0.1"
assert_contains "${isolated_dns}" "no-resolv"
assert_not_contains "${isolated_dns}" "server="

pinned_render=$(
  WIPI_SOURCE_ONLY=1 bash -c "
    source '${wipi}'
    set_defaults
    WIPI_PASSWORD=validpass
    WIPI_MODE=routed
    WIPI_UPSTREAM_INTERFACE=eth0
    validate_logical_settings
    PINNED_DNS_SERVERS=\$'192.0.2.53\n9.9.9.9'
    render_firewall
    render_dnsmasq_config
  "
)
assert_contains "${pinned_render}" \
  'iifname "wlan0" ip saddr 10.10.0.0/24 oifname "eth0" accept'
assert_contains "${pinned_render}" \
  'iifname "eth0" oifname "wlan0" ip daddr 10.10.0.0/24 ct state established,related accept'
assert_contains "${pinned_render}" \
  'iifname "wlan0" ip saddr 10.10.0.0/24 drop'
for blocked_interface in wlan1 usb0 tailscale0 tun0 wg0 docker0; do
  assert_not_contains "${pinned_render}" \
    "oifname \"${blocked_interface}\" accept"
done
assert_not_contains "${pinned_render}" "hook input"
assert_not_contains "${pinned_render}" "hook output"
assert_contains "${pinned_render}" \
  'iifname "wlan0" ip saddr 10.10.0.0/24 oifname "eth0" masquerade'
if grep -Eq '^[[:space:]]*masquerade([[:space:]]|$)' <<<"${pinned_render}"; then
  fail "pinned mode rendered a generic masquerade rule"
fi
assert_contains "${pinned_render}" "server=192.0.2.53@eth0"
assert_contains "${pinned_render}" "server=9.9.9.9@eth0"
assert_not_contains "${pinned_render}" "100.100.100.100"

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

mock_bin="${temporary}/bin"
mock_root="${temporary}/root"
mock_state="${temporary}/state"
mkdir -p "${mock_bin}" "${mock_root}/run/systemd/system" "${mock_state}"
mkdir -p "${temporary}/sys/eth0" "${temporary}/sys/usb0"
mkdir -p "${temporary}/sys/ethcarrier"
printf '1\n' >"${temporary}/sys/eth0/carrier"
printf '1\n' >"${temporary}/sys/usb0/carrier"
printf '0\n' >"${temporary}/sys/ethcarrier/carrier"
touch "${mock_state}/nm-profile" "${mock_state}/commands.log"
touch "${mock_state}/ip-rules" "${mock_state}/ip-table" \
  "${mock_state}/nft-state"
printf 'manual\n' >"${mock_state}/nm-method"
printf '0\n' >"${mock_state}/forwarding"

cat >"${mock_bin}/nmcli" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'nmcli %s\n' "$*" >>"${MOCK_LOG}"
if [[ $* == "--terse --fields NAME connection show" ]]; then
  [[ -e ${MOCK_NM_PROFILE} ]] && printf 'wipi\n'
elif [[ $* == "--terse --fields NAME connection show --active" ]]; then
  [[ -e ${MOCK_NM_ACTIVE} ]] && printf 'wipi\n'
elif [[ $* == "--escape no -g connection.type connection show wipi" ]]; then
  printf '802-11-wireless\n'
elif [[ $* == "--escape no -g ipv4.method connection show wipi" ]]; then
  cat "${MOCK_NM_METHOD}"
elif [[ $* == "connection add "* ]]; then
  touch "${MOCK_NM_PROFILE}"
elif [[ $* == "connection delete wipi" ]]; then
  rm -f "${MOCK_NM_PROFILE}" "${MOCK_NM_ACTIVE}"
elif [[ $* == "connection delete wipi-ap" ]]; then
  :
elif [[ $* == "connection modify "* ]]; then
  previous=
  for argument in "$@"; do
    if [[ ${previous} == "ipv4.method" ]]; then
      printf '%s\n' "${argument}" >"${MOCK_NM_METHOD}"
    fi
    previous=${argument}
  done
elif [[ $* == "connection up wipi" ]]; then
  touch "${MOCK_NM_ACTIVE}"
elif [[ $* == "connection down wipi" ]]; then
  rm -f "${MOCK_NM_ACTIVE}"
elif [[ $* == "--terse --escape no --fields IP4.DNS device show eth0" ]]; then
  if [[ ${MOCK_NO_DNS:-0} != "1" ]]; then
    printf 'IP4.DNS[1]:192.0.2.53\nIP4.DNS[2]:9.9.9.9\n'
  fi
elif [[ $* == "--terse --escape no --fields IP4.DNS device show usb0" ]]; then
  printf 'IP4.DNS[1]:203.0.113.53\n'
elif [[ $* == "--terse --escape no --fields IP4.DNS device show "* ]]; then
  printf 'IP4.DNS[1]:100.100.100.100\n'
fi
EOF

cat >"${mock_bin}/iw" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'iw %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "dev wlan0 info")
    printf 'Interface wlan0\n\twiphy 0\n\ttype AP\n'
    ;;
  "dev ethmonitor info")
    printf 'Interface ethmonitor\n\twiphy 2\n\ttype monitor\n'
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

cat >"${mock_bin}/ip" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'ip %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "link show dev wlan0"|"link show dev eth0"|"link show dev usb0")
    exit 0
    ;;
  "-o link show dev eth0"|"-o link show dev usb0")
    printf '2: %s: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\n' \
      "${*: -1}"
    ;;
  "-o link show dev ethdown")
    printf '3: ethdown: <BROADCAST,MULTICAST> mtu 1500 state DOWN\n'
    ;;
  "-o link show dev ethnoip"|"-o link show dev ethnoroute"|"-o link show dev ethmonitor"|"-o link show dev ethoverlap"|"-o link show dev ethcarrier")
    printf '3: %s: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\n' \
      "${*: -1}"
    ;;
  "-o -4 address show dev eth0 scope global")
    printf '2: eth0 inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0\n'
    ;;
  "-o -4 address show dev usb0 scope global")
    printf '4: usb0 inet 203.0.113.10/24 brd 203.0.113.255 scope global usb0\n'
    ;;
  "-o -4 address show dev ethnoip scope global")
    ;;
  "-o -4 address show dev ethnoroute scope global")
    printf '5: ethnoroute inet 198.18.0.10/24 scope global ethnoroute\n'
    ;;
  "-o -4 address show dev ethmonitor scope global")
    printf '6: ethmonitor inet 198.19.0.10/24 scope global ethmonitor\n'
    ;;
  "-o -4 address show dev ethoverlap scope global")
    printf '7: ethoverlap inet 10.10.0.20/24 scope global ethoverlap\n'
    ;;
  "-o -4 address show dev ethcarrier scope global")
    printf '8: ethcarrier inet 198.20.0.10/24 scope global ethcarrier\n'
    ;;
  "-o -4 address show up scope global")
    printf '2: eth0 inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0\n'
    printf '3: wlan1 inet 198.51.100.10/24 scope global wlan1\n'
    printf '4: docker0 inet 172.17.0.1/16 scope global docker0\n'
    if [[ ${MOCK_OVERLAP:-0} == "1" ]]; then
      printf '5: podman0 inet 10.10.0.50/24 scope global podman0\n'
    fi
    ;;
  "-4 route show dev eth0")
    printf 'default via 192.0.2.1 dev eth0\n'
    printf '192.0.2.0/24 dev eth0 proto kernel scope link src 192.0.2.10\n'
    printf '9.9.9.9 via 192.0.2.1 dev eth0\n'
    ;;
  "-4 route show default dev eth0")
    printf 'default via 192.0.2.1 dev eth0\n'
    ;;
  "-4 route show dev usb0")
    printf 'default via 203.0.113.1 dev usb0\n'
    printf '203.0.113.0/24 dev usb0 proto kernel scope link src 203.0.113.10\n'
    ;;
  "-4 route show default dev usb0")
    printf 'default via 203.0.113.1 dev usb0\n'
    ;;
  "-4 route show dev ethnoroute"|"-4 route show default dev ethnoroute")
    ;;
  "-4 route show dev ethmonitor")
    printf '198.19.0.0/24 dev ethmonitor scope link\n'
    ;;
  "-4 route show default dev ethmonitor")
    ;;
  "-4 route show dev ethoverlap")
    printf '10.10.0.0/24 dev ethoverlap scope link\n'
    ;;
  "-4 route show default dev ethoverlap")
    ;;
  "-4 route show dev ethcarrier")
    printf '198.20.0.0/24 dev ethcarrier scope link\n'
    ;;
  "-4 route show default dev ethcarrier")
    ;;
  "-4 rule show")
    [[ -r ${MOCK_IP_RULES} ]] && cat "${MOCK_IP_RULES}"
    ;;
  "-4 rule add "*)
    printf '10424: from 10.10.0.0/24 iif wlan0 lookup 4242\n' \
      >"${MOCK_IP_RULES}"
    ;;
  "-4 rule delete "*)
    : >"${MOCK_IP_RULES}"
    ;;
  "-4 route flush table 4242")
    : >"${MOCK_IP_TABLE}"
    ;;
  "-4 route replace table 4242 "*)
    printf '%s\n' "${*:6}" >>"${MOCK_IP_TABLE}"
    ;;
  "-4 route show table 4242")
    [[ -r ${MOCK_IP_TABLE} ]] && cat "${MOCK_IP_TABLE}"
    ;;
  "-4 route get "*)
    destination=$4
    upstream=eth0
    grep -q 'dev usb0' "${MOCK_IP_TABLE}" 2>/dev/null && upstream=usb0
    printf '%s via 192.0.2.1 dev %s table 4242 src 192.0.2.10\n' \
      "${destination}" "${upstream}"
    ;;
  "-4 route show default")
    printf 'default via 192.0.2.1 dev eth0\n'
    ;;
  "-4 route show")
    printf 'default via 192.0.2.1 dev eth0\n'
    ;;
  "-brief link show dev wlan0"|"-4 address show dev wlan0")
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${mock_bin}/nft" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'nft %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "delete table inet wipi_filter")
    if [[ -r ${MOCK_NFT_STATE} ]]; then
      awk '/^table ip wipi_nat/{show=1} show' "${MOCK_NFT_STATE}" \
        >"${MOCK_NFT_STATE}.tmp"
      mv "${MOCK_NFT_STATE}.tmp" "${MOCK_NFT_STATE}"
    fi
    ;;
  "delete table ip wipi_nat")
    if [[ -r ${MOCK_NFT_STATE} ]]; then
      awk '/^table ip wipi_nat/{exit} {print}' "${MOCK_NFT_STATE}" \
        >"${MOCK_NFT_STATE}.tmp"
      mv "${MOCK_NFT_STATE}.tmp" "${MOCK_NFT_STATE}"
    fi
    ;;
  "-f -")
    [[ ${MOCK_NFT_FAIL:-0} != "1" ]] || exit 1
    cat >"${MOCK_NFT_STATE}"
    ;;
  "list table inet wipi_filter")
    grep -q '^table inet wipi_filter' "${MOCK_NFT_STATE}" 2>/dev/null ||
      exit 1
    awk '/^table inet wipi_filter/{show=1} /^table ip wipi_nat/{show=0} show' \
      "${MOCK_NFT_STATE}"
    ;;
  "list table ip wipi_nat")
    grep -q '^table ip wipi_nat' "${MOCK_NFT_STATE}" 2>/dev/null ||
      exit 1
    awk '/^table ip wipi_nat/{show=1} show' "${MOCK_NFT_STATE}"
    ;;
  "list ruleset")
    printf 'table ip unrelated_nat { chain postrouting { ip saddr 192.168.0.0/16 masquerade; } }\n'
    [[ -r ${MOCK_NFT_STATE} ]] && cat "${MOCK_NFT_STATE}"
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${mock_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'systemctl %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "is-enabled wipi.service")
    exit 0
    ;;
  "is-active --quiet wipi-dnsmasq.service")
    [[ -e ${MOCK_DNS_ACTIVE} ]]
    ;;
  "restart wipi-dnsmasq.service"|"start wipi-dnsmasq.service")
    [[ ${MOCK_DNS_FAIL:-0} != "1" ]] || exit 1
    touch "${MOCK_DNS_ACTIVE}"
    ;;
  "stop wipi-dnsmasq.service"|"disable --now wipi-dnsmasq.service")
    rm -f "${MOCK_DNS_ACTIVE}"
    ;;
  "start wipi.service"|"restart wipi.service")
    [[ ${MOCK_WIPI_START_FAIL:-0} != "1" ]]
    ;;
  "--no-pager --full status wipi-dnsmasq.service")
    [[ -e ${MOCK_DNS_ACTIVE} ]] && printf 'Active: active (running)\n'
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat >"${mock_bin}/sysctl" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'sysctl %s\n' "$*" >>"${MOCK_LOG}"
case $* in
  "-n net.ipv4.ip_forward")
    cat "${MOCK_FORWARDING}"
    ;;
  "-q -w net.ipv4.ip_forward="*)
    printf '%s\n' "${*##*=}" >"${MOCK_FORWARDING}"
    ;;
esac
EOF

for command in rfkill dnsmasq; do
  cat >"${mock_bin}/${command}" <<EOF
#!/usr/bin/env bash
printf '${command} %s\\n' "\$*" >>"\${MOCK_LOG}"
EOF
done
chmod +x "${mock_bin}/"*

mock_env=(
  "PATH=${mock_bin}:${PATH}"
  "MOCK_LOG=${mock_state}/commands.log"
  "MOCK_NM_PROFILE=${mock_state}/nm-profile"
  "MOCK_NM_ACTIVE=${mock_state}/nm-active"
  "MOCK_NM_METHOD=${mock_state}/nm-method"
  "MOCK_IP_RULES=${mock_state}/ip-rules"
  "MOCK_IP_TABLE=${mock_state}/ip-table"
  "MOCK_NFT_STATE=${mock_state}/nft-state"
  "MOCK_DNS_ACTIVE=${mock_state}/dns-active"
  "MOCK_FORWARDING=${mock_state}/forwarding"
  "WIPI_SYS_CLASS_NET_ROOT=${temporary}/sys"
  "WIPI_TEST_MODE=1"
  "WIPI_TEST_ROOT=${mock_root}"
)

expect_runtime_validation_failure() {
  local interface=$1 expected=$2 extra_name=${3:-} extra_value=${4:-}
  local output
  local -a environment=("${mock_env[@]}")
  if [[ -n ${extra_name} ]]; then
    environment+=("${extra_name}=${extra_value}")
  fi
  if output=$(
    env "${environment[@]}" WIPI_SOURCE_ONLY=1 \
      WIPI_UPSTREAM_INTERFACE="${interface}" bash -c "
        source '${wipi}'
        set_defaults
        WIPI_PASSWORD=validpass
        WIPI_MODE=routed
        WIPI_UPSTREAM_INTERFACE='${interface}'
        validate_settings
      " 2>&1
  ); then
    fail "upstream validation unexpectedly accepted ${interface}"
  fi
  assert_contains "${output}" "${expected}"
}

expect_runtime_validation_failure "missing0" "does not exist"
expect_runtime_validation_failure "ethdown" "is down"
expect_runtime_validation_failure "ethcarrier" "has no carrier"
expect_runtime_validation_failure "ethnoip" "has no IPv4 address"
expect_runtime_validation_failure "ethnoroute" "no usable route"
expect_runtime_validation_failure "ethmonitor" "is in monitor mode"
expect_runtime_validation_failure "ethoverlap" "overlaps"
expect_runtime_validation_failure "eth0" "overlaps" "MOCK_OVERLAP" "1"

env "${mock_env[@]}" "${wipi}" install \
  --password validpass --mode isolated >/dev/null
env "${mock_env[@]}" "${wipi}" install --mode isolated >/dev/null

assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_ADDRESS="10.10.0.1/24"'
profile_add_count=$(grep -c '^nmcli connection add ' \
  "${mock_state}/commands.log" || true)
[[ ${profile_add_count} == "0" ]] ||
  fail "an existing profile was duplicated"
assert_file_contains "${mock_root}/etc/systemd/system/wipi-dnsmasq.service" \
  "Type=simple"
assert_file_contains "${mock_root}/etc/systemd/system/wipi-dnsmasq.service" \
  "ExecStart=/usr/sbin/dnsmasq --no-daemon"
assert_file_contains "${mock_root}/etc/systemd/system/wipi-dnsmasq.service" \
  "Restart=on-failure"
assert_file_contains "${mock_root}/etc/iproute2/rt_tables.d/wipi.conf" \
  "4242 wipi"
assert_file_contains \
  "${mock_root}/etc/NetworkManager/dispatcher.d/90-wipi" \
  "_network-changed"

env "${mock_env[@]}" "${wipi}" mode isolated >/dev/null
assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_UPSTREAM_INTERFACE=""'
env "${mock_env[@]}" "${wipi}" mode routed \
  --upstream-interface auto >/dev/null
assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_MODE="routed"'
assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_UPSTREAM_INTERFACE=""'
env "${mock_env[@]}" "${wipi}" mode routed \
  --upstream-interface eth0 >/dev/null
assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_UPSTREAM_INTERFACE="eth0"'
env "${mock_env[@]}" "${wipi}" _network-changed eth0 dhcp4-change
assert_file_contains "${mock_state}/commands.log" \
  "systemctl --no-block try-restart wipi.service"

if env "${mock_env[@]}" "${wipi}" mode isolated \
  --upstream-interface eth0 >/dev/null 2>&1; then
  fail "isolated mode accepted an upstream interface"
fi
if env "${mock_env[@]}" "${wipi}" mode routed >/dev/null 2>&1; then
  fail "routed mode accepted a missing upstream selection"
fi

printf '198.18.0.0/24 dev unrelated0\n' >"${mock_state}/ip-table"
if env "${mock_env[@]}" "${wipi}" _service-start >/dev/null 2>&1; then
  fail "pinned mode claimed a routing table already in use"
fi
assert_file_contains "${mock_state}/ip-table" "dev unrelated0"
: >"${mock_state}/ip-table"

if ! pinned_start_output=$(env "${mock_env[@]}" \
  "${wipi}" _service-start 2>&1); then
  tail -n 30 "${mock_state}/commands.log" >&2
  fail "pinned service start failed: ${pinned_start_output}"
fi
assert_file_contains "${mock_state}/ip-rules" \
  "from 10.10.0.0/24 iif wlan0 lookup 4242"
assert_file_contains "${mock_state}/ip-table" \
  "10.10.0.0/24 dev wlan0"
assert_file_contains "${mock_state}/ip-table" \
  "192.0.2.0/24 dev eth0"
assert_file_contains "${mock_state}/nft-state" \
  'iifname "wlan0" ip saddr 10.10.0.0/24 oifname "eth0" masquerade'
assert_file_contains "${mock_root}/run/wipi/dnsmasq.conf" \
  "server=192.0.2.53@eth0"
assert_not_contains "$(<"${mock_root}/run/wipi/dnsmasq.conf")" \
  "100.100.100.100"

pinned_status=$(env "${mock_env[@]}" "${wipi}" status)
assert_status_value "${pinned_status}" "Routing behavior" "pinned"
assert_status_value "${pinned_status}" "Policy rule" "active"
assert_status_value "${pinned_status}" "NAT rule" "eth0 only"
assert_status_value "${pinned_status}" "DNS upstream" "eth0"
assert_status_value "${pinned_status}" "Egress pinning" "enforced"
assert_not_contains "${pinned_status}" "validpass"

stale_rules=$(<"${mock_state}/nft-state")
stale_rules=${stale_rules//eth0/usb0}
printf '%s\n' "${stale_rules}" >"${mock_state}/nft-state"
stale_status=$(env "${mock_env[@]}" "${wipi}" status)
assert_status_value "${stale_status}" "Forwarding filter" "missing"
assert_status_value "${stale_status}" "Egress pinning" "not enforced"

env "${mock_env[@]}" "${wipi}" _service-start
rule_count=$(grep -c '^10424:' "${mock_state}/ip-rules" || true)
nat_count=$(grep -c ' masquerade' "${mock_state}/nft-state" || true)
[[ ${rule_count} == "1" && ${nat_count} == "1" ]] ||
  fail "repeated pinned start duplicated policy or NAT state"

: >"${mock_state}/ip-rules"
missing_policy_status=$(env "${mock_env[@]}" "${wipi}" status)
assert_status_value "${missing_policy_status}" "Policy rule" "missing"
assert_status_value "${missing_policy_status}" "Egress pinning" "not enforced"

env "${mock_env[@]}" "${wipi}" _service-start
env "${mock_env[@]}" nft delete table ip wipi_nat
missing_nat_status=$(env "${mock_env[@]}" "${wipi}" status)
assert_status_value "${missing_nat_status}" "NAT rule" "missing"
assert_status_value "${missing_nat_status}" "Egress pinning" "not enforced"

env "${mock_env[@]}" MOCK_NO_DNS=1 "${wipi}" _service-start
no_dns_status=$(env "${mock_env[@]}" MOCK_NO_DNS=1 "${wipi}" status)
assert_status_value "${no_dns_status}" "DNS upstream" "none \\(unavailable\\)"
assert_status_value "${no_dns_status}" "Egress pinning" "enforced"
assert_not_contains "$(<"${mock_root}/run/wipi/dnsmasq.conf")" "server="

env "${mock_env[@]}" "${wipi}" mode routed \
  --upstream-interface usb0 >/dev/null
env "${mock_env[@]}" "${wipi}" _service-start
assert_file_contains "${mock_state}/nft-state" 'oifname "usb0" masquerade'
assert_not_contains "$(<"${mock_state}/nft-state")" \
  'oifname "eth0" masquerade'
assert_file_contains "${mock_state}/ip-table" "203.0.113.0/24 dev usb0"

env "${mock_env[@]}" "${wipi}" mode routed \
  --upstream-interface auto >/dev/null
env "${mock_env[@]}" "${wipi}" _service-start
[[ ! -s ${mock_state}/ip-rules ]] ||
  fail "automatic mode left a policy rule"
[[ ! -s ${mock_state}/nft-state ]] ||
  fail "automatic mode left WiPi nftables state"
[[ ! -e ${mock_state}/dns-active ]] ||
  fail "automatic mode left WiPi dnsmasq active"
automatic_status=$(env "${mock_env[@]}" "${wipi}" status)
assert_status_value "${automatic_status}" "Routing behavior" "automatic"
assert_status_value "${automatic_status}" "Egress pinning" "disabled"
assert_status_value "${automatic_status}" "NAT ownership" "NetworkManager"

env "${mock_env[@]}" "${wipi}" mode isolated >/dev/null
env "${mock_env[@]}" "${wipi}" _service-start
[[ ! -s ${mock_state}/ip-rules ]] ||
  fail "isolated mode left a policy rule"
assert_not_contains "$(<"${mock_state}/nft-state")" "masquerade"
isolated_status=$(env "${mock_env[@]}" "${wipi}" status)
assert_status_value "${isolated_status}" "Routing behavior" "management only"
assert_status_value "${isolated_status}" "NAT" "disabled"
assert_status_value "${isolated_status}" "Forwarding rule" "active"

env "${mock_env[@]}" "${wipi}" mode routed \
  --upstream-interface eth0 >/dev/null
if env "${mock_env[@]}" MOCK_DNS_FAIL=1 "${wipi}" _service-start \
  >/dev/null 2>&1; then
  fail "pinned startup unexpectedly survived dnsmasq failure"
fi
[[ ! -s ${mock_state}/ip-rules ]] ||
  fail "failure after policy routing did not remove the rule"
[[ ! -s ${mock_state}/ip-table ]] ||
  fail "failure after policy routing did not flush table 4242"
[[ ! -s ${mock_state}/nft-state ]] ||
  fail "failure after NAT did not remove WiPi nftables state"
[[ ! -e ${mock_state}/dns-active ]] ||
  fail "failure left WiPi dnsmasq active"

env "${mock_env[@]}" "${wipi}" mode isolated >/dev/null
if env "${mock_env[@]}" MOCK_WIPI_START_FAIL=1 "${wipi}" configure \
  --mode routed --upstream-interface eth0 >/dev/null 2>&1; then
  fail "configuration transaction unexpectedly succeeded"
fi
assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_MODE="isolated"'
assert_file_contains "${mock_root}/etc/wipi/wipi.conf" \
  'WIPI_UPSTREAM_INTERFACE=""'

env "${mock_env[@]}" "${wipi}" start
env "${mock_env[@]}" "${wipi}" start
env "${mock_env[@]}" "${wipi}" stop
env "${mock_env[@]}" "${wipi}" stop

diagnostics=$(env "${mock_env[@]}" "${wipi}" diagnose)
assert_contains "${diagnostics}" 'WIPI_PASSWORD="<redacted>"'
assert_not_contains "${diagnostics}" "validpass"

firewall_log=$(<"${mock_state}/commands.log")
assert_not_contains "${firewall_log}" "flush ruleset"
assert_not_contains "${firewall_log}" "delete table inet filter"
assert_contains "${firewall_log}" "delete table inet wipi_filter"
assert_contains "${firewall_log}" "route flush table 4242"

env "${mock_env[@]}" "${wipi}" uninstall --keep-config >/dev/null
[[ -f ${mock_root}/etc/wipi/wipi.conf ]] ||
  fail "uninstall --keep-config removed the configuration"
[[ ! -e ${mock_root}/etc/systemd/system/wipi.service ]] ||
  fail "uninstall left wipi.service"
[[ ! -e ${mock_root}/etc/systemd/system/wipi-dnsmasq.service ]] ||
  fail "uninstall left wipi-dnsmasq.service"
[[ ! -e ${mock_root}/etc/iproute2/rt_tables.d/wipi.conf ]] ||
  fail "uninstall left the policy-table registration"
[[ ! -e ${mock_root}/etc/NetworkManager/dispatcher.d/90-wipi ]] ||
  fail "uninstall left the NetworkManager dispatcher hook"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${installer}" "${wipi}" "$0"
else
  printf 'ShellCheck not installed; skipped static lint.\n'
fi

printf 'All checks passed.\n'
