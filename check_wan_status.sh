#!/bin/bash

# WAN VM Status Check Script
# このスクリプトをProxmoxホストで実行して、wan0とwan1の状態を確認します

echo "================================"
echo "WAN VM Status Check"
echo "================================"
echo ""

check_vm() {
    VMID=$1
    VMNAME=$2
    
    echo "--- Checking VM ${VMID} (${VMNAME}) ---"
    
    # VM status
    STATUS=$(qm status ${VMID} 2>/dev/null | awk '{print $2}')
    echo "Status: ${STATUS}"
    
    if [ "$STATUS" != "running" ]; then
        echo "  ⚠️  VM is not running!"
        echo ""
        return
    fi
    
    # VM configuration
    echo "Configuration:"
    qm config ${VMID} | grep -E "^(net|ipconfig|cicustom)" | sed 's/^/  /'
    
    echo ""
    
    # Try to get IP from QEMU agent (if available)
    echo "Attempting to get IP addresses from QEMU agent..."
    IPS=$(qm guest cmd ${VMID} network-get-interfaces 2>/dev/null | grep -oP '"ip-address":\s*"\K[^"]+' | grep -v "127.0.0.1" | head -n 2)
    if [ -n "$IPS" ]; then
        echo "  IP Addresses:"
        echo "$IPS" | sed 's/^/    /'
    else
        echo "  ⚠️  QEMU agent not available or no IPs found"
        echo "  You may need to wait for the VM to fully boot"
    fi
    
    echo ""
}

# Check both WAN VMs
check_vm 1000 "wan0"
check_vm 1001 "wan1"

echo "================================"
echo "Cloud-Init Snippet Check"
echo "================================"
echo ""

SNIPPET_PATH="/var/lib/vz/snippets/wan-passthrough.yaml"
if [ -f "$SNIPPET_PATH" ]; then
    echo "✓ Snippet file exists at: ${SNIPPET_PATH}"
    echo "File size: $(stat -f%z "$SNIPPET_PATH" 2>/dev/null || stat -c%s "$SNIPPET_PATH" 2>/dev/null) bytes"
else
    echo "✗ Snippet file NOT found at: ${SNIPPET_PATH}"
fi

echo ""
echo "================================"
echo "Next Steps"
echo "================================"
echo ""
echo "1. If VMs are running, SSH into them to check NAT setup:"
echo "   ssh user@<wan0-ip>"
echo ""
echo "2. On wan0/wan1 VMs, check the NAT setup log:"
echo "   sudo cat /var/log/nat-setup.log"
echo ""
echo "3. Check Cloud-Init status:"
echo "   sudo cloud-init status"
echo "   sudo cat /var/log/cloud-init-output.log"
echo ""
echo "4. Check IP forwarding:"
echo "   sudo sysctl net.ipv4.ip_forward"
echo ""
echo "5. Check iptables rules:"
echo "   sudo iptables -t nat -L -n -v"
echo "   sudo iptables -L FORWARD -n -v"
echo ""
echo "For detailed troubleshooting, see: troubleshooting.md"
echo ""
