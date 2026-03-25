#!/usr/bin/env bash

set -euo pipefail

# --- Default Variables ---
DEFAULT_END_IP="203.0.113.10"
DEFAULT_LISTEN_PORT="44884"
DEFAULT_TARGET_PORT="8443"

ACTION=${1:-""}
END_IP=${2:-$DEFAULT_END_IP}
LISTEN_PORT=${3:-$DEFAULT_LISTEN_PORT}
TARGET_PORT=${4:-$DEFAULT_TARGET_PORT}

TABLE_FAMILY="inet"
TABLE_NAME="middle_forward"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# --- Environment & Target Detection ---
HAS_IPV4=$(ip -4 addr show scope global 2>/dev/null | grep -q inet && echo 1 || echo 0)
HAS_IPV6=$(ip -6 addr show scope global 2>/dev/null | grep -q inet6 && echo 1 || echo 0)
IS_IPV6_TARGET=$(echo "$END_IP" | grep -q ":" && echo 1 || echo 0)

# --- Helper Functions ---
ufw_installed() { command -v ufw >/dev/null 2>&1; }
ufw_active() { ufw status 2>/dev/null | grep -Fq "Status: active"; }
table_exists() { nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; }

# Strict sysctl enforcement
set_sysctl_strict() {
    local key=$1
    local val=$2
    
    echo "==> Setting kernel parameter: $key=$val"
    if ! sysctl -w "$key=$val" >/dev/null 2>&1; then
        echo ""
        echo "❌ ERROR: Permission denied while modifying '$key'."
        echo "Hint: You are likely running in an unprivileged LXC container or a restricted"
        echo "environment where guest modification of kernel network parameters is blocked."
        echo "To fix this, you must either enable IP forwarding on the host machine itself,"
        echo "or run this script on a standard KVM/general-purpose VPS."
        echo "Exiting to prevent incomplete network configuration."
        exit 1
    fi
}

enable_ip_forward() {
    echo "==> Configuring IP forwarding"
    
    # Target is IPv6
    if [ "$IS_IPV6_TARGET" -eq 1 ]; then
        if [ "$HAS_IPV6" -eq 1 ]; then
            set_sysctl_strict net.ipv6.conf.all.forwarding 1
        else
            echo "❌ ERROR: Target is IPv6, but this machine has no global IPv6 address."
            exit 1
        fi
    # Target is IPv4
    else
        if [ "$HAS_IPV4" -eq 1 ]; then
            set_sysctl_strict net.ipv4.ip_forward 1
        else
            echo "❌ ERROR: Target is IPv4, but this machine is IPv6-only."
            exit 1
        fi
    fi
}

disable_ip_forward() {
    echo "==> Disabling IP forwarding"
    if [ "$HAS_IPV4" -eq 1 ]; then
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    fi
    if [ "$HAS_IPV6" -eq 1 ]; then
        sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
    fi
}

add_nft_forward_table() {
    local dnat_target="${END_IP}"
    local masquerade_rule=""
    local dnat_proto=""

    if [ "$IS_IPV6_TARGET" -eq 1 ]; then
        dnat_target="[${END_IP}]"
        masquerade_rule="ip6 daddr ${END_IP} masquerade"
        dnat_proto="ip6"
    else
        masquerade_rule="ip daddr ${END_IP} masquerade"
        dnat_proto="ip"
    fi

    nft -f - <<EOF
table ${TABLE_FAMILY} ${TABLE_NAME} {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${LISTEN_PORT} dnat ${dnat_proto} to ${dnat_target}:${TARGET_PORT}
        udp dport ${LISTEN_PORT} dnat ${dnat_proto} to ${dnat_target}:${TARGET_PORT}
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ${masquerade_rule}
    }
}
EOF
}

remove_nft_forward_table() {
    if table_exists; then
        nft delete table "$TABLE_FAMILY" "$TABLE_NAME"
    fi
}

add_ufw_rules() {
    if ufw_installed && ufw_active; then
        echo "==> Adding UFW rules"
        ufw allow "${LISTEN_PORT}/tcp" >/dev/null || true
        ufw allow "${LISTEN_PORT}/udp" >/dev/null || true
        ufw route allow proto tcp to "${END_IP}" port "${TARGET_PORT}" >/dev/null 2>&1 || true
    fi
}

remove_ufw_rules() {
    if ufw_installed && ufw_active; then
        echo "==> Removing UFW rules"
        ufw route delete allow proto tcp to "${END_IP}" port "${TARGET_PORT}" >/dev/null 2>&1 || true
        ufw delete allow "${LISTEN_PORT}/tcp" >/dev/null || true
        ufw delete allow "${LISTEN_PORT}/udp" >/dev/null || true
    fi
}

# --- Main Actions ---
start_forwarding() {
    # Suppress apt output to keep it clean
    apt-get update -qq && apt-get install -y nftables >/dev/null 2>&1
    
    enable_ip_forward
    remove_nft_forward_table
    
    echo "==> Adding nftables forwarding: ${LISTEN_PORT} -> ${END_IP}:${TARGET_PORT}"
    add_nft_forward_table
    add_ufw_rules
    echo "✅ Done. Forwarding started successfully."
}

stop_forwarding() {
    remove_nft_forward_table
    disable_ip_forward
    remove_ufw_rules
    echo "✅ Done. Forwarding stopped."
}

# --- Execution Logic ---
if [ -z "$ACTION" ]; then
    echo "1) Start forwarding"
    echo "2) Stop forwarding"
    read -rp "Action [1/2]: " CHOICE
    [[ "$CHOICE" == "1" ]] && ACTION="start" || ACTION="stop"
fi

case "$ACTION" in
    1|start|Start|START)
        start_forwarding
        ;;
    2|stop|Stop|STOP)
        stop_forwarding
        ;;
    *)
        echo "Invalid choice: $ACTION"
        exit 1
        ;;
esac

echo
echo "== nft ${TABLE_NAME} table =="
nft list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null || echo "(not present)"
