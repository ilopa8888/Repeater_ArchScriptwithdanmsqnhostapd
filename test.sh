
#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PHY_INT="${PHY_INT:-wlp2s0}"
AP_INT="${AP_INT:-ap0}"

AP_MAC="${AP_MAC:-02:5b:d8:73:67:8e}"

GATEWAY_IP="${GATEWAY_IP:-192.168.12.1/24}"

DNSMASQ_CONF="${DNSMASQ_CONF:-$SCRIPT_DIR/config/dnsmasq-repeater.conf}"
HOSTAPD_CONF="${HOSTAPD_CONF:-$SCRIPT_DIR/config/hostapd-repeater.conf}"

HOSTAPD_PID=""
DNSMASQ_PID=""

AP_CREATED=0
NAT_ADDED=0
FWD_IN_ADDED=0
FWD_OUT_ADDED=0

OLD_FORWARDING=""
OLD_WIFI_CONNECTION=""
WIFI_DISCONNECTED=0

# ==========================================
# ROOT CHECK
# ==========================================

if [[ $EUID -ne 0 ]]; then
    echo "Run using: sudo ./test.sh"
    exit 1
fi

# ==========================================
# CLEANUP
# ==========================================

cleanup() {
    local status=$?

    trap - EXIT INT TERM

    echo
    echo "Cleaning up..."

    if [[ -n "$HOSTAPD_PID" ]]; then
        kill "$HOSTAPD_PID" 2>/dev/null || true
        wait "$HOSTAPD_PID" 2>/dev/null || true
    fi

    if [[ -n "$DNSMASQ_PID" ]]; then
        kill "$DNSMASQ_PID" 2>/dev/null || true
        wait "$DNSMASQ_PID" 2>/dev/null || true
    fi

    if (( NAT_ADDED )); then
        iptables -w -t nat -D POSTROUTING \
            -o "$PHY_INT" -j MASQUERADE 2>/dev/null || true
    fi

    if (( FWD_IN_ADDED )); then
        iptables -w -D FORWARD \
            -i "$PHY_INT" -o "$AP_INT" \
            -m conntrack --ctstate RELATED,ESTABLISHED \
            -j ACCEPT 2>/dev/null || true
    fi

    if (( FWD_OUT_ADDED )); then
        iptables -w -D FORWARD \
            -i "$AP_INT" -o "$PHY_INT" \
            -j ACCEPT 2>/dev/null || true
    fi

    if [[ -n "$OLD_FORWARDING" ]]; then
        sysctl -q -w "net.ipv4.ip_forward=$OLD_FORWARDING" || true
    fi

    if (( AP_CREATED )); then
        ip link set "$AP_INT" down 2>/dev/null || true
        iw dev "$AP_INT" del 2>/dev/null || true
    fi

    if (( WIFI_DISCONNECTED )); then
        echo "Reconnecting the previous Wi-Fi connection..."
        if [[ -n "$OLD_WIFI_CONNECTION" && "$OLD_WIFI_CONNECTION" != "--" ]]; then
            nmcli connection up "$OLD_WIFI_CONNECTION" ifname "$PHY_INT" ||
                nmcli device connect "$PHY_INT" || true
        else
            nmcli device connect "$PHY_INT" || true
        fi
    fi

    echo "Cleanup complete."

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ==========================================
# DEPENDENCIES
# ==========================================

for cmd in iw ip iptables hostapd dnsmasq sysctl nmcli; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[-] Missing dependency: $cmd"
        exit 1
    }
done

[[ -f "$DNSMASQ_CONF" ]] || {
    echo "[-] Missing $DNSMASQ_CONF"
    exit 1
}

[[ -f "$HOSTAPD_CONF" ]] || {
    echo "[-] Missing $HOSTAPD_CONF"
    exit 1
}

grep -Fqx "interface=$AP_INT" "$DNSMASQ_CONF" || {
    echo "[-] Set interface=$AP_INT in $DNSMASQ_CONF"
    exit 1
}

grep -Fqx "interface=$AP_INT" "$HOSTAPD_CONF" || {
    echo "[-] Set interface=$AP_INT in $HOSTAPD_CONF"
    exit 1
}

echo "Checking dnsmasq configuration..."
dnsmasq --test -C "$DNSMASQ_CONF"

ip link show "$PHY_INT" >/dev/null 2>&1 || {
    echo "[-] Physical interface not found."
    exit 1
}

if ip link show "$AP_INT" >/dev/null 2>&1; then
    echo "AP interface '$AP_INT' already exists; choose another AP_INT or remove it manually."
    exit 1
fi

# ==========================================
# DISCONNECT WIFI
# ==========================================

OLD_WIFI_CONNECTION=$(nmcli -g GENERAL.CONNECTION device show "$PHY_INT" 2>/dev/null || true)
if [[ -n "$OLD_WIFI_CONNECTION" && "$OLD_WIFI_CONNECTION" != "--" ]]; then
    WIFI_DISCONNECTED=1
    echo "Disconnecting normal Wi-Fi..."
    nmcli device disconnect "$PHY_INT" || {
        echo "[-] Could not disconnect $PHY_INT from its current Wi-Fi network."
        exit 1
    }
    sleep 3
fi

# ==========================================
# CREATE VIRTUAL INTERFACE
# ==========================================

echo "Creating the AP interface..."

iw dev "$PHY_INT" interface add "$AP_INT" type managed

AP_CREATED=1

echo "Disabling NetworkManager management for the AP interface..."

nmcli device set "$AP_INT" managed no || true

echo "Setting the AP interface down..."

ip link set "$AP_INT" down

echo "Changing interface to AP mode..."

iw dev "$AP_INT" set type __ap

echo "Assigning the AP MAC address..."

ip link set "$AP_INT" address "$AP_MAC"

echo "Bringing the AP interface up..."

ip link set "$AP_INT" up

echo
echo "========== AP INTERFACE =========="

iw dev "$AP_INT" info

ip -details link show "$AP_INT"

# ==========================================
# CONFIGURE GATEWAY
# ==========================================

echo "Configuring the gateway..."

ip addr flush dev "$AP_INT"
ip addr add "$GATEWAY_IP" dev "$AP_INT"

# ==========================================
# ENABLE FORWARDING
# ==========================================

echo "Enabling IPv4 forwarding..."

OLD_FORWARDING=$(sysctl -n net.ipv4.ip_forward)

sysctl -q -w net.ipv4.ip_forward=1

# ==========================================
# NAT
# ==========================================

echo "Configuring IPv4 NAT and forwarding..."

if ! iptables -w -t nat -C POSTROUTING \
    -o "$PHY_INT" -j MASQUERADE 2>/dev/null; then

    iptables -w -t nat -A POSTROUTING \
        -o "$PHY_INT" -j MASQUERADE

    NAT_ADDED=1
fi

if ! iptables -w -C FORWARD \
    -i "$PHY_INT" -o "$AP_INT" \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null; then

    iptables -w -A FORWARD \
        -i "$PHY_INT" -o "$AP_INT" \
        -m conntrack --ctstate RELATED,ESTABLISHED \
        -j ACCEPT

    FWD_IN_ADDED=1
fi

if ! iptables -w -C FORWARD \
    -i "$AP_INT" -o "$PHY_INT" \
    -j ACCEPT 2>/dev/null; then

    iptables -w -A FORWARD \
        -i "$AP_INT" -o "$PHY_INT" \
        -j ACCEPT

    FWD_OUT_ADDED=1
fi

# ==========================================
# DNSMASQ
# ==========================================

echo "Starting dnsmasq..."

dnsmasq \
    --no-daemon \
    --conf-file="$DNSMASQ_CONF" &

DNSMASQ_PID=$!

sleep 2

kill -0 "$DNSMASQ_PID" 2>/dev/null || {
    echo "dnsmasq failed to start."
    exit 1
}

echo "dnsmasq is running."

# ==========================================
# HOSTAPD
# ==========================================

echo "Starting hostapd..."

hostapd "$HOSTAPD_CONF" &

HOSTAPD_PID=$!

sleep 3

kill -0 "$HOSTAPD_PID" 2>/dev/null || {
    echo "hostapd failed to start."
    exit 1
}

# ==========================================
# SUCCESS
# ==========================================

echo
echo "=========================================="
echo "       Wi-Fi access point is running"
echo "=========================================="

echo "Physical interface : $PHY_INT"
echo "AP interface       : $AP_INT"
echo "AP MAC             : $AP_MAC"
echo "Gateway            : $GATEWAY_IP"
echo "Hostapd PID        : $HOSTAPD_PID"
echo "Dnsmasq PID        : $DNSMASQ_PID"

echo "=========================================="

echo
echo "[*] Press CTRL+C to stop and restore Wi-Fi."

wait "$HOSTAPD_PID"
