#!/bin/bash

# ------------------------------------------------------------------------------
# NETWORK.SH
# ------------------------------------------------------------------------------
set -e
source $INSTALLER/000-source

# ------------------------------------------------------------------------------
# ENVIRONMENT
# ------------------------------------------------------------------------------
MACH="$TAG-host"
cd $MACHINES/$MACH

# public interface
DEFAULT_ROUTE=$(ip route | egrep '^default ' | head -n1)
PUBLIC_INTERFACE=${DEFAULT_ROUTE##*dev }
PUBLIC_INTERFACE=${PUBLIC_INTERFACE/% */}
echo PUBLIC_INTERFACE="$PUBLIC_INTERFACE" >> $INSTALLER/000-source

# IP address (IP used in the private bridge network)
DNS_RECORD=$(grep 'address=/host/' etc/dnsmasq.d/$TAG-hosts | head -n1)
IP=${DNS_RECORD##*/}
echo HOST="$IP" >> $INSTALLER/000-source

# remote IP address (IP used for remote connections)
REMOTE_IP=$(ip addr show $PUBLIC_INTERFACE | ack "$PUBLIC_INTERFACE$" | \
            xargs | cut -d " " -f2 | cut -d "/" -f1)
echo REMOTE_IP="$REMOTE_IP" >> $INSTALLER/000-source

# external IP (Internet IP)
EXTERNAL_IP=$(curl -s ifconfig.me || true)
echo EXTERNAL_IP="$EXTERNAL_IP" >> $INSTALLER/000-source

# ------------------------------------------------------------------------------
# INIT
# ------------------------------------------------------------------------------
[[ "$DONT_RUN_NETWORK_INIT" = true ]] && exit

echo
echo "------------------------ NETWORK --------------------------"

# ------------------------------------------------------------------------------
# BACKUP & STATUS
# ------------------------------------------------------------------------------
OLD_FILES="/root/$TAG-old-files/$DATE"
mkdir -p $OLD_FILES

# backup the files which will be changed
[[ -f /etc/nftables.conf ]] && cp /etc/nftables.conf $OLD_FILES/
[[ -f /etc/network/interfaces ]] && cp /etc/network/interfaces $OLD_FILES/
[[ -f /etc/dnsmasq.conf ]] && cp /etc/dnsmasq.conf $OLD_FILES/
[[ -f /etc/lxc-net ]] && cp /etc/lxc-net $OLD_FILES/
[[ -f /etc/dnsmasq.d/$TAG-hosts ]] && cp /etc/dnsmasq.d/$TAG-hosts $OLD_FILES/

# network status
echo "# ----- ip addr -----" >> $OLD_FILES/network.status
ip addr >> $OLD_FILES/network.status
echo >> $OLD_FILES/network.status
echo "# ----- ip route -----" >> $OLD_FILES/network.status
ip route >> $OLD_FILES/network.status

# nftables status
if [[ "$(systemctl is-active nftables.service)" = "active" ]]; then
    echo "# ----- nft list ruleset -----" >> $OLD_FILES/nftables.status
    nft list ruleset >> $OLD_FILES/nftables.status
fi

# ------------------------------------------------------------------------------
# PACKAGES
# ------------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

# added packages
dnf $APT_PROXY -y install nftables NetworkManager-initscripts-updown

# ------------------------------------------------------------------------------
# NETWORK CONFIG
# ------------------------------------------------------------------------------
# changed/added system files
cp etc/dnsmasq.d/$TAG-hosts /etc/dnsmasq.d/
cp etc/dnsmasq.d/$TAG-resolv /etc/dnsmasq.d/
[[ -z "$(egrep '^DNSMASQ_EXCEPT' /etc/dnsmasq.conf)" ]] && \
    sed -i "s/^#DNSMASQ_EXCEPT/DNSMASQ_EXCEPT/" /etc/dnsmasq.conf

# IP forwarding
cp etc/sysctl.d/$TAG-ip-forward.conf /etc/sysctl.d/
sysctl -p /etc/sysctl.d/$TAG-ip-forward.conf || true
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" != 1 ]] && false

# ------------------------------------------------------------------------------
# LXC-NET
# ------------------------------------------------------------------------------
cp etc/default/lxc-net /etc/
systemctl restart lxc-net.service

# ------------------------------------------------------------------------------
# DUMMY INTERFACE & BRIDGE
# ------------------------------------------------------------------------------

# the random MAC address for the dummy interface
MAC_ADDRESS=$(date +'52:54:%d:%H:%M:%S')
# Rocy create dummy0 interface
nmcli connection add type dummy ifname dummy0 ethernet.mac-address $MAC_ADDRESS

# the random MAC address for the bridge interface
MAC_ADDRESS=$(date +'52:54:%d:%H:%M:%S')
# Rocy create bridge copy from /etc/NetworkManager/system-connections/eb.nmconnection to /etc/dnsmasq.d/
nmcli connection add type bridge ifname $TAG con-name $TAG ipv4.method manual ipv4.addresses "172.22.22.1/24" ethernet.mac-address $MAC_ADDRESS

cp etc/dnsmasq.d/$TAG-interface /etc/dnsmasq.d/
sed -i "s/___BRIDGE___/${BRIDGE}/g" /etc/dnsmasq.d/$TAG-interface

nmcli connection up dummy-dummy0
nmcli connection up $TAG

# ------------------------------------------------------------------------------
# NFTABLES
# ------------------------------------------------------------------------------
# recreate the custom tables
if [[ "$RECREATE_CUSTOM_NFTABLES" = true ]]; then
    nft delete table inet $TAG-filter 2>/dev/null || true
    nft delete table ip $TAG-nat 2>/dev/null || true
fi

# table: $TAG-filter
# chains: input, forward, output
# rules: drop from the public interface to the private internal network
nft add table inet $TAG-filter
nft add chain inet $TAG-filter \
    input { type filter hook input priority 0 \; }
nft add chain inet $TAG-filter \
    forward { type filter hook forward priority 0 \; }
nft add chain inet $TAG-filter \
    output { type filter hook output priority 0 \; }
[[ -z "$(nft list chain inet $TAG-filter output | \
ack 'ip daddr 172.22.22.0/24 drop')" ]] && \
    nft add rule inet $TAG-filter output \
    iif $PUBLIC_INTERFACE ip daddr 172.22.22.0/24 drop

# table: $TAG-nat
# chains: prerouting, postrouting, output, input
# rules: masquerade
nft add table ip $TAG-nat
nft add chain ip $TAG-nat prerouting \
    { type nat hook prerouting priority 0 \; }
nft add chain ip $TAG-nat postrouting \
    { type nat hook postrouting priority 100 \; }
nft add chain ip $TAG-nat output \
    { type nat hook output priority 0 \; }
nft add chain ip $TAG-nat input \
    { type nat hook input priority 0 \; }
[[ -z "$(nft list chain ip $TAG-nat postrouting | \
ack 'ip saddr 172.22.22.0/24 masquerade')" ]] && \
    nft add rule ip $TAG-nat postrouting \
    ip saddr 172.22.22.0/24 masquerade

# table: $TAG-nat
# chains: prerouting
# maps: tcp2ip, tcp2port
# rules: tcp dnat
nft add map ip $TAG-nat tcp2ip \
    { type inet_service : ipv4_addr \; }
nft add map ip $TAG-nat tcp2port \
    { type inet_service : inet_service \; }
[[ -z "$(nft list chain ip $TAG-nat prerouting | \
ack 'tcp dport map @tcp2ip:tcp dport map @tcp2port')" ]] && \
    nft add rule ip $TAG-nat prerouting \
    iif $PUBLIC_INTERFACE dnat \
    tcp dport map @tcp2ip:tcp dport map @tcp2port

# table: $TAG-nat
# chains: prerouting
# maps: udp2ip, udp2port
# rules: udp dnat
nft add map ip $TAG-nat udp2ip \
    { type inet_service : ipv4_addr \; }
nft add map ip $TAG-nat udp2port \
    { type inet_service : inet_service \; }
[[ -z "$(nft list chain ip $TAG-nat prerouting | \
ack 'udp dport map @udp2ip:udp dport map @udp2port')" ]] && \
    nft add rule ip $TAG-nat prerouting \
    iif $PUBLIC_INTERFACE dnat \
    udp dport map @udp2ip:udp dport map @udp2port

# ------------------------------------------------------------------------------
# NETWORK RELATED SERVICES
# ------------------------------------------------------------------------------
# dnsmasq
systemctl stop dnsmasq.service
systemctl start dnsmasq.service

# nftables
systemctl enable nftables.service
systemctl start nftables.service
# ------------------------------------------------------------------------------
# STATUS
# ------------------------------------------------------------------------------
ip addr
