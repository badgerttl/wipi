# WiPi

WiPi turns a NetworkManager-based Raspberry Pi into a focused management access
point. One command installs, configures, starts, stops, diagnoses, switches, and
removes the AP:

```sh
sudo wipi <command>
```

WiPi has two explicit operating modes.

## Routed mode

Use routed mode when a phone or laptop connected to WiPi should access:

- The Internet
- A wired target network
- Other upstream IP networks

NetworkManager provides DHCP, forwarded DNS, IPv4 routing, and NAT through
`ipv4.method shared`. If an upstream interface is pinned, WiPi adds a narrowly
scoped filter that permits AP-client forwarding only through that interface.

This is Layer 3 routing and NAT, not an Ethernet bridge. LLDP, CDP, ARP scanning,
DHCP discovery, raw Ethernet, and VLAN-tagged traffic do not cross it.

## Isolated mode

Use isolated mode when the AP should provide access only to:

- Local dashboards
- Local APIs
- Services running on the Pi

Clients receive DHCP from WiPi's dedicated dnsmasq process and can resolve the
configured local hostname. Normal DNS queries are not forwarded. A WiPi-owned
nftables table blocks all forwarding into or out of the AP interface, so there
is no upstream routing or NAT even if another application has enabled global IP
forwarding.

WiPi does not open or manage dashboard ports. Local services should bind to the
AP address (or deliberately to all addresses); bind to the AP address when they
must not be exposed through another Pi interface.

## Assessment-appliance layout

A typical dedicated appliance can keep each interface in one role:

```text
wlan0 = WiPi management AP
wlan1 = Wi-Fi monitor adapter
eth0  = wired inspection interface
```

WiPi defaults only to `wlan0` and never searches for or silently selects another
wireless interface. Wi-Fi sniffing and monitoring tools can use `wlan1`, while
LLDP/CDP and other Layer 2 tools can run directly on `eth0`. A laptop on the AP
can perform upstream TCP or UDP probing only in routed mode. Layer 2 inspection
must run directly on the Pi's target-facing interface.

## Install

On Raspberry Pi OS Bookworm or newer:

```sh
sudo ./wipi install --mode isolated
```

`install.sh` remains as a compatibility launcher:

```sh
sudo ./install.sh --mode isolated
```

The installed command is `/usr/local/bin/wipi`. Installation creates one
NetworkManager profile named `wipi`, one systemd service, and a persistent
configuration at `/etc/wipi/wipi.conf`.

WiPi generates a cryptographically random WPA2 password when no password is
provided and prints it only at installation. Retrieve it later only with:

```sh
sudo wipi credentials
```

Install routed mode with automatic route-table selection:

```sh
sudo ./wipi install --mode routed
```

Or pin AP-client forwarding to one existing interface:

```sh
sudo ./wipi install --mode routed --upstream-interface eth0
```

WiPi installs only missing dependencies and runs `apt-get update` no more than
once per installation run. It does not change NetworkManager's Wi-Fi backend or
disable unrelated network services.

## Configure

Saved settings use a simple, validated format:

```sh
WIPI_INTERFACE="wlan0"
WIPI_SSID="wipi"
WIPI_PASSWORD="generated-password"
WIPI_ADDRESS="10.42.0.1/24"
WIPI_HOSTNAME="wipi.local"
WIPI_COUNTRY="US"
WIPI_BAND="2.4"
WIPI_CHANNEL="6"
WIPI_MODE="isolated"
WIPI_UPSTREAM_INTERFACE=""
```

The file is mode `0600`. WiPi parses only these keys and never sources or
evaluates the file. Values are validated again before use.

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

Or run `sudo wipi configure` in a terminal for a short interactive prompt.
Passwords entered by that prompt are hidden. Environment variables with the
same names as the saved keys can override settings during `install` and
`configure`; successful changes are written back to the configuration file.

WiPi currently restricts AP networks to `/24`. This keeps DHCP range
calculation predictable and prevents unsafe small-subnet edge cases. The AP
address itself may use any valid host address in that `/24`; the generated DHCP
range avoids it.

Switch modes persistently:

```sh
sudo wipi mode isolated
sudo wipi mode routed
```

For routed mode, choose automatic routing or pin one interface:

```sh
sudo wipi configure --mode routed --upstream-interface eth0
sudo wipi configure --mode routed --upstream-interface auto
```

Isolated mode always clears the upstream-interface setting.

## Radio and security settings

WiPi validates that the explicitly selected interface exists, is wireless,
supports AP mode, and can initiate an AP on the requested channel. It defaults
to 2.4 GHz channel 6. Supported 5 GHz channels are the non-DFS channels 36, 40,
44, and 48.

The NetworkManager profile uses:

- WPA2-PSK with RSN and CCMP
- A password of 8 to 63 bytes
- A permanent AP MAC address
- Wi-Fi power saving disabled in the profile and reinforced with `iw`
- A 20 MHz channel width when the installed NetworkManager exposes that setting
- The configured two-letter regulatory country

The Raspberry Pi 4 BCM43455 has an AP-mode interoperability problem when
Protected Management Frames are negotiated. WiPi explicitly sets NetworkManager
PMF enum `1` (`disable`) for compatibility. WPA2 data encryption remains
enabled, but management frames such as deauthentication frames are not
cryptographically protected.

## Manage

```sh
sudo wipi start
sudo wipi stop
sudo wipi restart
sudo wipi status
sudo wipi diagnose
sudo wipi credentials
sudo wipi uninstall
```

`status` reports the mode, interface, SSID, channel, address, client count,
DHCP/DNS behavior, forwarding, NAT, upstream, default route, and autostart state.
It never prints the WPA password.

`diagnose` is intentionally AP-focused. It shows:

- Configuration with the password redacted
- Interface, address, AP capabilities, power saving, and rfkill state
- NetworkManager and `wipi` profile state
- Associated clients
- Routes and IPv4-forwarding state
- WiPi-owned nftables rules
- Recent NetworkManager messages related to Wi-Fi, `wipi`, or the AP interface

## Firewall and forwarding ownership

WiPi never flushes the host firewall.

In isolated mode it owns only `table inet wipi_filter`, whose forward hook drops
packets entering from or leaving through the AP interface. Traffic terminating
on the Pi is unaffected.

In routed mode without a pinned upstream, NetworkManager owns the shared-mode
forwarding and masquerade rules. With a pinned upstream, WiPi adds only its
`wipi_filter` table to allow AP traffic through the selected interface, allow
established replies, and drop unrelated or new inbound forwarding. NetworkManager
still owns NAT.

WiPi records the prior `net.ipv4.ip_forward` value only when routed mode needs
it. If WiPi changed that value, it restores the saved value when routed mode
stops or switches to isolated mode. Isolation does not depend on the global
value because the interface-specific firewall remains authoritative.

## Isolated DHCP and DNS

Isolated mode uses a dedicated dnsmasq configuration and PID file under
`/run/wipi`. It binds only to the AP interface and address, serves DHCP only for
the AP `/24`, resolves only the configured local hostname, and uses `no-resolv`
and `no-hosts` so normal client DNS is not forwarded.

WiPi does not change system-wide dnsmasq configuration and never kills
system-wide `dnsmasq`, `hostapd`, `wpa_supplicant`, or unrelated processes.

## Uninstall

```sh
sudo wipi uninstall
```

Uninstall removes only WiPi-owned resources: its command, systemd unit,
NetworkManager profiles, configuration, runtime/state directories, dnsmasq
process/configuration, and nftables tables. It does not uninstall dependencies,
change NetworkManager's backend, delete unrelated profiles, or flush unrelated
firewall rules.

Keep the saved configuration with:

```sh
sudo wipi uninstall --keep-config
```

## Development and test plan

Run:

```sh
./tests/check.sh
```

The automated checks cover syntax, configuration validation, routed and
isolated rendering, profile idempotency, repeated lifecycle operations, mode
switching, security settings, password redaction, firewall ownership, and
protection against automatic `wlan1` selection. Hardware and privileged tools
are mocked.

Before deploying to an assessment Pi, also perform a hardware integration pass:

1. Associate two clients and verify DHCP, local hostname resolution, and local
   services in isolated mode.
2. Confirm Internet/target TCP and UDP access in routed mode.
3. Confirm isolated clients cannot reach any upstream address even when another
   application enables global forwarding.
4. Pin `eth0` and confirm no AP-client traffic exits `wlan1` or another
   interface.
5. Reboot after each mode and confirm the persisted mode and autostart state.
