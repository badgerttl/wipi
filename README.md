# WiPi

WiPi turns a NetworkManager-based Raspberry Pi into a management access point.
Installation, configuration, mode switching, lifecycle management, status,
diagnostics, and removal all use one primary command:

```sh
sudo wipi <command>
```

## Default network

Fresh installations use:

```text
AP interface:  wlan0
AP address:    10.10.0.1/24
AP subnet:     10.10.0.0/24
DHCP range:    10.10.0.10-10.10.0.100
Hostname:      wipi.local
Mode:          isolated
```

WiPi supports `/24` AP networks. It rejects an AP subnet that overlaps an
active local interface, including wired or wireless interfaces, container
bridges, and VPN interfaces.

## Operating modes

### Isolated

Isolated mode is a management-only AP:

```sh
sudo wipi mode isolated
```

Clients receive DHCP and can resolve `wipi.local` to the Pi's AP address. They
can reach services running directly on the Pi, but cannot be forwarded into or
out of any other interface. WiPi does not enable NAT or forward normal DNS
queries in this mode.

NetworkManager configures the AP with a manual IPv4 address. A dedicated
dnsmasq instance supplies DHCP and local-only DNS. WiPi's nftables filter drops
forwarded traffic entering from or leaving through the AP while leaving traffic
terminating on the Pi untouched.

### Routed with automatic egress

Automatic routed mode follows the Pi's normal routing table:

```sh
sudo wipi mode routed --upstream-interface auto
```

The NetworkManager profile uses `ipv4.method shared`. NetworkManager owns DHCP,
DNS forwarding, forwarding, and NAT. WiPi removes its pinned policy-routing,
NAT, filter, and dnsmasq state before activating this mode.

Automatic mode is deliberately reported as unpinned. A default-route change,
VPN, or more-specific route on the Pi can change where AP-client traffic exits.

### Routed with pinned egress

Pinned mode restricts AP-client IP traffic to one selected interface:

```sh
sudo wipi mode routed --upstream-interface eth0
```

The path is:

```text
phone or laptop
  -> wlan0
  -> source policy rule
  -> routing table 4242
  -> WiPi forwarding filter
  -> WiPi eth0-only NAT
  -> eth0
```

WiPi validates that `eth0` exists, is up, has carrier when available, has a
non-link-local IPv4 address, has a useful connected or default route, does not
overlap the AP subnet, and is not a monitor-mode wireless interface.

Pinned mode uses:

- A source-and-input-interface rule for AP-client traffic only
- Routing table `4242`, registered as `wipi`
- Routes derived from the selected interface's live address and route data
- `table inet wipi_filter` to allow only AP-to-`eth0` forwarding and established
  replies
- `table ip wipi_nat` with an AP-subnet and `eth0`-scoped masquerade rule
- Dedicated DHCP and DNS through WiPi's supervised dnsmasq service

The policy rule includes `iif wlan0`, so locally generated Pi traffic is not
forced through table 4242.

WiPi never invents a gateway. Without an `eth0` default route, directly
connected target-network access can still work. Startup fails if no useful
route through the selected interface can be built. A small NetworkManager
dispatcher hook restarts the active WiPi service when the pinned interface
changes, rebuilding table 4242 from current address and route data.

## Pinned DNS

For pinned mode, WiPi asks NetworkManager only for DNS servers associated with
the selected upstream interface. Its dnsmasq configuration contains:

```text
no-resolv
server=<eth0 DNS address>@eth0
```

DNS servers from Wi-Fi sniffing adapters, VPNs, Tailscale, container networks,
or other interfaces are not imported. Every configured DNS destination is
route-checked through table 4242, and dnsmasq binds forwarded queries to the
selected interface.

If the selected interface has no usable DNS server, the AP still supports
direct-IP upstream connectivity. Status reports DNS as unavailable rather than
silently using another interface's resolver.

## Assessment-appliance layout

A typical appliance can keep each interface in one role:

```text
wlan0 = WiPi AP
wlan1 = Wi-Fi sniffing and monitoring adapter
eth0  = wired inspection and pinned routed egress
```

Wi-Fi sniffing tools can operate directly on `wlan1`. LLDP, CDP, ARP discovery,
DHCP discovery, raw Ethernet, and VLAN tools must run directly on `eth0`. A
phone or laptop on the AP can perform IP-based investigation through `eth0` in
pinned routed mode. Layer 2 traffic is not routed or NATed through the AP.

## Install

On Raspberry Pi OS Bookworm or Trixie:

```sh
sudo ./wipi install --mode isolated
```

`install.sh` is a compatibility launcher for the same operation:

```sh
sudo ./install.sh --mode isolated
```

The installed command is `/usr/local/bin/wipi`. WiPi installs only missing
dependencies and runs `apt-get update` at most once per installation. It does
not change NetworkManager's Wi-Fi backend or manage unrelated services.

A secure random WPA2 password is generated when none is supplied. Installation
prints it once. Display it explicitly later with:

```sh
sudo wipi credentials
```

Install either routed variant directly:

```sh
sudo ./wipi install --mode routed --upstream-interface auto
sudo ./wipi install --mode routed --upstream-interface eth0
```

## Configure

Persistent configuration is stored at `/etc/wipi/wipi.conf` with mode `0600`:

```sh
WIPI_INTERFACE="wlan0"
WIPI_SSID="wipi"
WIPI_PASSWORD="generated-password"
WIPI_ADDRESS="10.10.0.1/24"
WIPI_HOSTNAME="wipi.local"
WIPI_COUNTRY="US"
WIPI_BAND="2.4"
WIPI_CHANNEL="6"
WIPI_MODE="isolated"
WIPI_UPSTREAM_INTERFACE=""
```

WiPi allowlists these keys and parses values without `source` or `eval`.
Persistent writes are atomic.

Configure with flags:

```sh
sudo wipi configure \
  --interface wlan0 \
  --ssid management-ap \
  --mode isolated \
  --address 10.10.0.1/24 \
  --hostname wipi.local \
  --country US \
  --band 2.4 \
  --channel 6
```

Pinned routed configuration is also available through `configure`:

```sh
sudo wipi configure --mode routed --upstream-interface eth0
```

Running `sudo wipi configure` without flags opens a short interactive prompt.
The password prompt is hidden. Environment variables named like the saved keys
can override values during `install` and `configure`.

Mode/configuration activation is transactional. WiPi validates the candidate,
stops the previous mode, clears stale WiPi-owned runtime state, applies and
verifies the candidate, and only keeps it after successful activation. On
failure it removes partial policy, firewall, NAT, and DNS state and restores
the previous configuration and profile where practical.

## Existing-default migration

An existing saved address is migrated only when it is exactly the former WiPi
default, `10.42.0.1/24`. That one value becomes `10.10.0.1/24`, a migration
message is logged, and the configuration is written atomically. Any other
custom address is preserved. Once written, subsequent starts do not repeat the
migration.

## AP security and reliability

WiPi preserves the Raspberry Pi AP safeguards:

- WPA2-PSK with RSN and CCMP
- A random password of 8 to 63 bytes
- PMF enum `1` (`disable`) for BCM43455 AP compatibility
- NetworkManager power saving disabled and reinforced with `iw`
- Permanent AP MAC address
- Regulatory-country configuration
- AP capability and channel validation
- Non-DFS 5 GHz channels 36, 40, 44, and 48
- 20 MHz channel width when supported by NetworkManager

Disabling PMF improves BCM43455 compatibility but leaves management frames such
as deauthentication frames without cryptographic protection. WPA2 data
encryption remains enabled.

## Systemd services

WiPi installs:

```text
wipi.service
wipi-dnsmasq.service
```

`wipi.service` owns AP activation and cleanup. `wipi-dnsmasq.service` uses
`Type=simple`, runs dnsmasq in the foreground, and has `Restart=on-failure`.
It is started only for isolated and pinned routed modes. A dnsmasq crash is
therefore visible to systemd and triggers restart handling.

WiPi's dnsmasq files are:

```text
/run/wipi/dnsmasq.conf
/run/wipi/dnsmasq.pid
```

WiPi does not edit `/etc/dnsmasq.conf`, restart a system-wide dnsmasq service,
or use broad process matching.

## Owned firewall and routing state

WiPi owns only:

```text
table inet wipi_filter
table ip wipi_nat
ip rule priority 10424, iif wlan0, from the AP subnet, lookup 4242
routing table 4242
/etc/iproute2/rt_tables.d/wipi.conf
/etc/NetworkManager/dispatcher.d/90-wipi
```

The NAT table exists only in pinned routed mode. Its rule is scoped to both the
AP subnet and selected upstream, for example:

```nft
iifname "wlan0" ip saddr 10.10.0.0/24 oifname "eth0" masquerade
```

WiPi never flushes the complete nftables ruleset, modifies the main routing
table, or removes unrelated policy rules. Reconfiguration and uninstall delete
only the named WiPi tables, priority/table combination, and table 4242 routes.

WiPi records the previous `net.ipv4.ip_forward` value under `/var/lib/wipi`
before changing it. It restores that value only when WiPi changed it and no
current WiPi routed mode needs forwarding. Isolated enforcement remains valid
when another application owns global forwarding.

## Status and diagnostics

```sh
sudo wipi status
sudo wipi diagnose
```

Status distinguishes configured mode from verified runtime state:

- Isolated mode reports DHCP, local-only DNS, forwarding-filter state, and
  unexpected NAT.
- Automatic mode reports host-route selection, NetworkManager sharing, and NAT
  verification separately, and always reports pinning disabled.
- Pinned mode verifies the source rule, table 4242, a route-only lookup, scoped
  filter/NAT rules, supervised DNS, stale-interface absence, and DNS routes.

`Egress pinning: enforced` appears only when all pinned components verify.
Status and diagnostics never print the WPA password. Route verification uses
`ip route get`; WiPi does not send pings, probes, scans, or application traffic.

## Manage and uninstall

```sh
sudo wipi start
sudo wipi stop
sudo wipi restart
sudo wipi credentials
sudo wipi uninstall
sudo wipi uninstall --keep-config
```

Uninstall removes the two WiPi units, command, profiles, configuration unless
kept, runtime/state directories, nftables tables, priority rule, routing table,
and table-name registration. It does not uninstall dependencies, remove
unrelated NetworkManager profiles, change the Wi-Fi backend, or flush unrelated
firewall/routing state.

## Development

Run:

```sh
./tests/check.sh
shellcheck wipi
```

The mock suite covers configuration validation and migration, address/DHCP
defaults, interface and overlap failures, mode CLI parsing, automatic cleanup,
pinned rule/table/NAT/DNS construction, route-only verification, status claims,
idempotency, supervised dnsmasq, rollback, password redaction, and ownership
boundaries.

Hardware integration is still required before appliance deployment. In
particular, verify Bookworm/Trixie nftables rendering, NetworkManager route/DNS
data, BCM43455 association, carrier transitions, and upstream route changes on
the target Pi.
