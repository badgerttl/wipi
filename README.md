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
  WIPI_CHANNEL="6" \
  WIPI_ADDRESS="10.42.0.1/24" \
  ./install.sh
```

Re-running the installer safely replaces the `wipi-ap` profile with the new
settings.

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

## Development

Run the local checks before committing:

```sh
./tests/check.sh
```

The check validates both scripts with Bash and also runs ShellCheck when it is
installed.
