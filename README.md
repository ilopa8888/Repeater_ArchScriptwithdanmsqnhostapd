# Linux Wi-Fi Repeater

A small Bash script that creates a WPA2-protected Wi-Fi access point using a Linux wireless adapter. The AP receives IPv4 addresses from `dnsmasq`; IPv4 traffic is forwarded and NATed through the existing Wi-Fi interface.

Use this only on a computer and network you own or are authorized to administer. Starting the AP disconnects the computer's normal Wi-Fi connection for the duration of the run. Press **Ctrl+C** to stop the script and let it remove the resources it created.

## Requirements

- Linux with a Wi-Fi adapter and driver that support creating an AP interface (`nl80211`) on the same radio.
- The adapter must support the script's interface mode and AP operation. Some adapters cannot create a second virtual interface; check `iw list` for supported interface combinations.
- NetworkManager and `nmcli`.
- `iw`, `ip` (`iproute2`), `iptables`, `sysctl` (`procps`), `hostapd`, `dnsmasq`, and Bash.
- Root privileges (`sudo`) to create interfaces and configure forwarding/firewall rules.
- A working upstream Wi-Fi connection before starting.

On Debian or Ubuntu, install the common packages with:

```sh
sudo apt update
sudo apt install iw iproute2 iptables procps hostapd dnsmasq network-manager
```

Package names and NetworkManager behavior can differ on other distributions.

## Configure

1. Edit `config/hostapd-repeater.conf`:
   - Choose a network name in `ssid=`.
   - Replace `wpa_passphrase` with a unique, private password of 8–63 characters.
   - Uncomment `country_code` and set your two-letter regulatory country code; choose a channel permitted in your location. Check your hostapd and local regulatory requirements.
2. Edit `config/dnsmasq-repeater.conf` if you change the AP interface or gateway/subnet.
3. If your upstream interface is not `wlp2s0`, pass its name as `PHY_INT`. Set `AP_INT` to an unused interface name. The `AP_INT` value must match the `interface=` setting in both config files.
4. Ensure no other process is already using the selected AP interface or the AP's DHCP/DNS ports.

The sample AP subnet is `192.168.12.0/24`, with gateway `192.168.12.1` and DHCP leases from `192.168.12.20` through `192.168.12.200`. Keep the gateway and DHCP range consistent if you change the subnet.

The configs are project-local. The script does not overwrite `/etc/dnsmasq.conf` or stop unrelated `hostapd`/`dnsmasq` services. If a separate service conflicts with the AP interface or ports, stop or reconfigure only the service you administer before running this script.

## Run

From this directory, connect the computer to the upstream Wi-Fi, then run:

```sh
sudo ./test.sh
```

To select a different upstream/AP interface, provide environment overrides. For example:

```sh
sudo env PHY_INT=wlan0 AP_INT=ap0 ./test.sh
```

Keep the config files' `interface=` values in sync with `AP_INT`. The script reports its gateway and interface details when the AP starts. Connect a client to the configured SSID and password.

Stop with **Ctrl+C**. The script tracks its own child processes and firewall rules, removes the AP interface it created, restores the previous IPv4 forwarding setting, and attempts to reconnect the prior NetworkManager Wi-Fi connection.

## Limitations and cautions

- This script configures IPv4 DHCP, forwarding, and NAT only; it does not set up IPv6 routing or firewall rules.
- It temporarily interrupts the upstream Wi-Fi connection. It is not a background service and does not automatically start at boot.
- A successful configuration test does not guarantee that the Wi-Fi adapter/driver supports simultaneous virtual interfaces or AP mode.
- Firewall behavior can vary when another firewall manager is active. Review your firewall rules before running it on a machine with existing network policies.
- The sample password is a placeholder and must be replaced before use.

## Checks

Check Bash syntax without bringing up an access point:

```sh
bash -n ./test.sh
dnsmasq --test --conf-file=./config/dnsmasq-repeater.conf
```

`hostapd` configuration validation may require a compatible wireless device and can attempt device initialization; do not treat a live AP test as a syntax-only check.

## Suggested commit message

Copy this subject if you add these files to a Git repository:

```text
feat(network): add configurable Linux Wi-Fi repeater setup
```
