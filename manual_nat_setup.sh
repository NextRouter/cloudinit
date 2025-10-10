#!/bin/bash

# Manual NAT Setup Script
# このスクリプトをwan0/wan1 VM内で実行して、手動でNATを設定します
# 使用方法: sudo ./manual_nat_setup.sh

echo "================================"
echo "Manual NAT Setup for WAN VM"
echo "================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Please run as root (use sudo)"
    exit 1
fi

echo "Step 1: Detecting network interfaces..."
echo ""

# Detect interfaces
ALL_IFS=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|ens)' | grep -v "lo")
echo "Available interfaces:"
echo "$ALL_IFS" | nl

# Try to detect WAN interface (one with default route)
WAN_IF=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$WAN_IF" ]; then
    echo ""
    echo "⚠️  Could not auto-detect WAN interface"
    echo "Please enter WAN interface name (typically the one connected to external network with DHCP):"
    read WAN_IF
else
    echo ""
    echo "✓ Detected WAN interface: $WAN_IF"
fi

# Detect LAN interface
LAN_IF=$(echo "$ALL_IFS" | grep -v "$WAN_IF" | head -n1)

if [ -z "$LAN_IF" ]; then
    echo ""
    echo "⚠️  Could not auto-detect LAN interface"
    echo "Please enter LAN interface name:"
    read LAN_IF
else
    echo "✓ Detected LAN interface: $LAN_IF"
fi

echo ""
echo "Configuration:"
echo "  WAN Interface: $WAN_IF"
echo "  LAN Interface: $LAN_IF"
echo ""

# Confirm
read -p "Is this correct? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "Step 2: Installing required packages..."
apt-get update -qq
apt-get install -y iptables iptables-persistent netfilter-persistent

echo ""
echo "Step 3: Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.forwarding=1

# Make it persistent
cat > /etc/sysctl.d/99-ip-forward.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
EOF

sysctl -p /etc/sysctl.d/99-ip-forward.conf

echo ""
echo "Step 4: Configuring iptables rules..."

# Clear existing rules
iptables -t nat -F
iptables -t nat -X
iptables -F FORWARD

# Setup NAT
iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
iptables -A FORWARD -i $LAN_IF -o $WAN_IF -j ACCEPT
iptables -A FORWARD -i $WAN_IF -o $LAN_IF -m state --state RELATED,ESTABLISHED -j ACCEPT

# Set default FORWARD policy to ACCEPT
iptables -P FORWARD ACCEPT

echo ""
echo "Step 5: Saving iptables rules..."
netfilter-persistent save

echo ""
echo "Step 6: Creating systemd service for persistence..."

cat > /usr/local/bin/setup-nat.sh <<SCRIPT
#!/bin/bash
# Auto-generated NAT setup script

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.forwarding=1

# Setup NAT rules
iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
iptables -A FORWARD -i $LAN_IF -o $WAN_IF -j ACCEPT
iptables -A FORWARD -i $WAN_IF -o $LAN_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -P FORWARD ACCEPT

# Save rules
netfilter-persistent save

exit 0
SCRIPT

chmod +x /usr/local/bin/setup-nat.sh

cat > /etc/systemd/system/setup-nat.service <<SERVICE
[Unit]
Description=Setup NAT forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable setup-nat.service

echo ""
echo "================================"
echo "✓ NAT Setup Complete!"
echo "================================"
echo ""
echo "Current Configuration:"
echo ""
echo "IP Forwarding:"
sysctl net.ipv4.ip_forward

echo ""
echo "NAT Rules:"
iptables -t nat -L -n -v

echo ""
echo "FORWARD Rules:"
iptables -L FORWARD -n -v

echo ""
echo "Interface Status:"
ip addr show $WAN_IF | grep "inet "
ip addr show $LAN_IF | grep "inet "

echo ""
echo "✓ NAT is now configured and will persist across reboots"
echo ""
