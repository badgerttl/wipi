# wipi

Turn a Raspberry Pi into a private Wi-Fi access point with one command. Devices
that join the network receive an IP address automatically and can reach services
running on the Pi at `10.42.0.1`.

## Install

On a Raspberry Pi running Raspberry Pi OS Bookworm or newer:

```sh
sudo ./install.sh
```

The installer generates a secure password and prints it when installation
finishes. It configures NetworkManager's built-in DHCP, DNS, and connection
sharing, then starts the access point immediately and after every reboot.

To choose the network name and password:

```sh
sudo WIPI_SSID="My Pi" WIPI_PASSWORD="choose-a-secure-password" ./install.sh
```

Useful optional settings:

```sh
sudo \
  WIPI_SSID="My Pi" \
  WIPI_PASSWORD="choose-a-secure-password" \
  WIPI_COUNTRY="US" \
  WIPI_INTERFACE="wlan0" \
  WIPI_BAND="2.4" \
  WIPI_CHANNEL="6" \
  WIPI_ADDRESS="10.42.0.1/24" \
  ./install.sh
```

Re-running the installer upgrades the installation while preserving the current
SSID, password, address, band, and channel. Set an environment option to change
it.

## Choose a Wi-Fi band

Both 2.4 and 5 GHz use the same WPA2/CCMP and Raspberry Pi 4 compatibility
settings.

Use 2.4 GHz for greater range, better wall penetration, and compatibility with
older or IoT devices:

```sh
sudo WIPI_COUNTRY="US" WIPI_BAND="2.4" WIPI_CHANNEL="6" ./install.sh
```

Channels 1, 6, and 11 are the usual non-overlapping 2.4 GHz choices. The default
is channel 6.

Use 5 GHz for nearby modern devices, less congestion, and more responsive SSH
or service access:

```sh
sudo WIPI_COUNTRY="US" WIPI_BAND="5" WIPI_CHANNEL="36" ./install.sh
```

The installer supports non-DFS 5 GHz channels 36, 40, 44, and 48. Channel 36 is
the default. Set `WIPI_COUNTRY` to the Pi's actual two-letter country code so
NetworkManager applies the correct regulatory rules.

If `WIPI_CHANNEL` is omitted when switching bands, the installer automatically
chooses channel 6 for 2.4 GHz and channel 36 for 5 GHz.

## Reach a service

The service must listen on all interfaces, not only localhost. For example:

```sh
python3 -m http.server 8000 --bind 0.0.0.0
```

After joining the `wipi` Wi-Fi network, open:

```text
http://10.42.0.1:8000
```

The same pattern works for any TCP or UDP service. If a firewall such as UFW is
enabled, allow the service port on the Wi-Fi interface.

## Manage

```sh
sudo wipi status
sudo wipi diagnose
sudo wipi restart
sudo wipi stop
sudo wipi start
sudo wipi uninstall
```

## Requirements

- Raspberry Pi OS or Debian
- A Wi-Fi adapter with access-point mode support
- Internet access during installation only if NetworkManager is not installed

Current Raspberry Pi OS releases include NetworkManager. The installer adds it
with `apt` when necessary.

## Raspberry Pi 4 compatibility

The BCM43455 Wi-Fi firmware used by Raspberry Pi 4 has limited Protected
Management Frame support in access-point mode. When PMF is negotiated, clients
can associate successfully but sustained Pi-to-client traffic can stall. This
matches a [documented BCM43455 AP-mode
limitation](https://github.com/raspberrypi/linux/issues/3619).

To avoid that failure mode, wipi explicitly configures:

- WPA2/RSN authentication with a pre-shared key
- CCMP/AES encryption
- Protected Management Frames disabled
- Wi-Fi power saving disabled
- A permanent access-point MAC address
- A 20 MHz channel width when supported by NetworkManager

Disabling PMF means the network does not cryptographically protect management
frames such as deauthentication messages. WPA2 data encryption remains enabled.
For this device-local access point, compatibility is favored over PMF support.
NetworkManager documents `1` as the
[`disable` PMF value](https://www.networkmanager.dev/docs/api/latest/nm-settings-nmcli.html).

Earlier development versions offered an experimental iwd backend. The installer
automatically migrates those installations back to NetworkManager's supported
`wpa_supplicant` backend.

## Troubleshooting

If an SSH session stalls, keep a second terminal running:

```sh
ping 10.42.0.1
```

If ping stalls at the same time, collect the Pi-side radio and power information
over Ethernet:

```sh
sudo wipi diagnose
```

For intermittent SSH stalls, run the diagnostic command over Ethernet while the
Wi-Fi session is actively frozen. The report includes the SSH socket's unacked
data, retransmission state, Wi-Fi interface counters, and transmit queue.

Check `vcgencmd get_throttled` in the output. A value other than `0x0` can
indicate a present or previous undervoltage or thermal event. Also try channels
1, 6, and 11; re-run the installer with, for example, `WIPI_CHANNEL=1`.

In the connected-station output, a transmit rate stuck at 1 Mbit/s together
with a growing `tx failed` count points to an RF or Wi-Fi driver problem rather
than an SSH service problem. The diagnostic report includes the channel survey
and `brcmfmac` kernel events needed to distinguish interference from a driver or
firmware failure.

If client-to-Pi transfers work but Pi-to-client transfers stall, verify that the
installed profile contains the compatibility setting:

```sh
nmcli -g 802-11-wireless-security.pmf connection show wipi-ap
```

The expected value is `1 (disable)`. Re-run `sudo ./install.sh` if it differs.

## Development

Run the local checks before committing:

```sh
./tests/check.sh
```

The check validates both scripts with Bash and also runs ShellCheck when it is
installed.
