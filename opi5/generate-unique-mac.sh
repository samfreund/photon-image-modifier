#!/bin/bash
NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/00-custom-macs.yaml"
NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_CONF_FILE="${NM_CONF_DIR}/10-mac-spoof.conf"
SUCCESS_FILE="${NETPLAN_DIR}/.mac-provisioned"
VALIDATION_DIR=""

set -euo pipefail

cleanup() {
    rm -f "${NETPLAN_FILE}.tmp" "${NM_CONF_FILE}.tmp"
    if [ -n "$VALIDATION_DIR" ]; then
        rm -rf "$VALIDATION_DIR"
    fi
}

trap cleanup EXIT

# Do not repeat a completed provisioning run. Incomplete output is repaired below.
if [ -f "$SUCCESS_FILE" ] && [ -s "$NETPLAN_FILE" ] && [ -s "$NM_CONF_FILE" ]; then
    exit 0
fi

# 1. Extract the unique hardware serial number
CPU_SERIAL=$(awk 'tolower($1) == "serial" { print $3; exit }' /proc/cpuinfo)
if [ -z "$CPU_SERIAL" ]; then
    CPU_SERIAL=$(cat /proc/sys/kernel/random/uuid)
fi

# 2. Slice the hash correctly for a standard 6-byte MAC address
HASH_BASE=$(echo -n "$CPU_SERIAL" | md5sum | cut -c1-6 | sed 's/../&:/g')

BYTE5_DEC=$(( 16#$(echo -n "$CPU_SERIAL" | md5sum | cut -c7-8) ))
BYTE6_DEC=$(( 16#$(echo -n "$CPU_SERIAL" | md5sum | cut -c9-10) ))

P1_B5=$(printf "%02X" $BYTE5_DEC)
P1_B6=$(printf "%02X" $BYTE6_DEC)

P2_B5=$(printf "%02X" $BYTE5_DEC)
P2_B6=$(printf "%02X" $(( (BYTE6_DEC + 1) % 256 )))

MAC1="02:${HASH_BASE}${P1_B5}:${P1_B6}"
MAC2="02:${HASH_BASE}${P2_B5}:${P2_B6}"

# 3. Dynamic Hardware Discovery (Scans physical wired interfaces)
mapfile -t ETHERNET_INTERFACES < <(
    for interface_path in /sys/class/net/*; do
        interface_name=${interface_path##*/}
        if [[ $interface_name =~ ^(eth|end)[0-9]+$ ]] && [ -e "$interface_path/device" ]; then
            printf '%s\n' "$interface_name"
        fi
    done | sort -V
)

# 5. Generate the Netplan YAML Structure and add a NetworkManager rule to
# honor the macaddr for new connections
if [ ${#ETHERNET_INTERFACES[@]} -gt 0 ]; then
    PORT1="${ETHERNET_INTERFACES[0]}"

    mkdir -p "$NETPLAN_DIR" "$NM_CONF_DIR"

    cat << EOF > "${NETPLAN_FILE}.tmp"
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    ${PORT1}:
      match:
        name: "${PORT1}"
      macaddress: "${MAC1}"
      dhcp4: true
      dhcp6: true
EOF

    cat << EOF > "${NM_CONF_FILE}.tmp"
[connection-${PORT1}]
    match-device=interface-name:${PORT1}
    ethernet.cloned-mac-address=${MAC1}
EOF

    # If the board is an Orange Pi 5 Plus, append the secondary interface layout
    if [ ${#ETHERNET_INTERFACES[@]} -gt 1 ]; then
        PORT2="${ETHERNET_INTERFACES[1]}"
        cat << EOF >> "${NETPLAN_FILE}.tmp"
    ${PORT2}:
      match:
        name: "${PORT2}"
      macaddress: "${MAC2}"
      dhcp4: true
      dhcp6: true
EOF

        cat << EOF >> "${NM_CONF_FILE}.tmp"
[connection-${PORT2}]
    match-device=interface-name:${PORT2}
    ethernet.cloned-mac-address=${MAC2}
EOF

    fi
else
    echo "No physical Ethernet interfaces found; MAC provisioning was not completed." >&2
    exit 1
fi

if ! command -v netplan >/dev/null 2>&1; then
    echo "netplan is required to complete MAC provisioning." >&2
    exit 1
fi

# Validate the generated Netplan before replacing the active configuration.
VALIDATION_DIR=$(mktemp -d)
mkdir -p "$VALIDATION_DIR/etc/netplan"
cp "${NETPLAN_FILE}.tmp" "$VALIDATION_DIR/etc/netplan/00-custom-macs.yaml"
if ! netplan generate --root-dir "$VALIDATION_DIR"; then
    echo "Generated Netplan configuration is invalid; MAC provisioning was not completed." >&2
    exit 1
fi

# Remove the Armbian default after validation so a failed run does not alter
# the existing network configuration.
rm -f "${NETPLAN_DIR}/10-dhcp-all-interfaces.yaml"

# Replace both files only after they have been generated successfully.
chmod 600 "${NETPLAN_FILE}.tmp" "${NM_CONF_FILE}.tmp"
rm -f "$SUCCESS_FILE"
mv -f "${NETPLAN_FILE}.tmp" "$NETPLAN_FILE"
mv -f "${NM_CONF_FILE}.tmp" "$NM_CONF_FILE"

# Apply Netplan changes instantly
netplan apply

# Mark success only after the configuration has been applied.
touch "$SUCCESS_FILE"
chmod 600 "$SUCCESS_FILE"
