#!/bin/bash

# Proxmox VM Creation Script for NextRouter

# --- Configuration ---
STORAGE_NAME="local-lvm"              # The name of the storage to use for the VM disks
TEMPLATE_VMID="9000"                  # VMID for the template
TEMPLATE_NAME="ubuntu-22.04-cloudinit" # The name for the template
IMAGE_URL="https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
IMAGE_NAME="ubuntu-22.04-server-cloudimg-amd64.img"
DOWNLOAD_DIR="/var/lib/vz/template/iso"

# SSH Public Key
# Reads the SSH public key from the 'nextrouter.pub' file.
# Ensure this file is in the same directory as the script.
SSH_PUBLIC_KEY=$(cat nextrouter.pub)

# --- Functions ---

# Function to setup the Ubuntu Cloud-Init template
setup_template() {
  echo "--- Checking for template VM ${TEMPLATE_VMID} (${TEMPLATE_NAME}) ---"
  if qm status ${TEMPLATE_VMID} > /dev/null 2>&1; then
    echo "Template already exists. Skipping setup."
    return
  fi

  echo "Template not found. Starting setup..."

  # Check for wget
  if ! command -v wget &> /dev/null; then
    echo "Error: wget is not installed. Please install it to download the cloud image."
    exit 1
  fi

  # Download image
  mkdir -p ${DOWNLOAD_DIR}
  if [ ! -f "${DOWNLOAD_DIR}/${IMAGE_NAME}" ]; then
    echo "Downloading Ubuntu cloud image..."
    wget -P ${DOWNLOAD_DIR} ${IMAGE_URL}
  else
    echo "Image already downloaded."
  fi

  # Create a new VM
  echo "Creating a new VM to become the template..."
  qm create ${TEMPLATE_VMID} --name ${TEMPLATE_NAME} --memory 2048 --net0 virtio,bridge=vmbr0

  # Import the downloaded disk to storage
  echo "Importing disk..."
  qm importdisk ${TEMPLATE_VMID} ${DOWNLOAD_DIR}/${IMAGE_NAME} ${STORAGE_NAME}

  # Attach the new disk to the VM
  echo "Attaching disk to VM..."
  qm set ${TEMPLATE_VMID} --scsihw virtio-scsi-pci --scsi0 ${STORAGE_NAME}:vm-${TEMPLATE_VMID}-disk-0

  # Configure cloud-init drive
  echo "Configuring Cloud-Init drive..."
  qm set ${TEMPLATE_VMID} --ide2 ${STORAGE_NAME}:cloudinit

  # Set boot disk
  echo "Setting boot disk..."
  qm set ${TEMPLATE_VMID} --boot c --bootdisk scsi0

  # Convert the VM to a template
  echo "Converting VM to template..."
  qm template ${TEMPLATE_VMID}

  # Clean up downloaded image
  echo "Cleaning up downloaded image..."
  rm "${DOWNLOAD_DIR}/${IMAGE_NAME}"

  echo "--- Template setup complete ---"
}


# Function to create a VM with common settings
create_vm() {
  VMID=$1
  VMNAME=$2
  CORES=$3
  MEMORY=$4
  DISK_SIZE=$5

  echo "--- Creating VM ${VMID} (${VMNAME}) ---"

  # Create the VM from the template
  qm clone ${TEMPLATE_VMID} ${VMID} --name ${VMNAME} --full

  # Configure hardware
  qm resize ${VMID} scsi0 ${DISK_SIZE}
  qm set ${VMID} --cores ${CORES} --memory ${MEMORY}

  # Configure Cloud-Init
  qm set ${VMID} --ciuser user --cipassword user
  qm set ${VMID} --sshkeys <(echo "${SSH_PUBLIC_KEY}")
  qm set ${VMID} --ide2 ${STORAGE_NAME}:cloudinit
}

# Function to create a WAN VM with NAT configuration
create_wan_vm() {
  VMID=$1
  VMNAME=$2
  CORES=$3
  MEMORY=$4
  DISK_SIZE=$5
  SNIPPET=$6

  echo "--- Creating WAN VM ${VMID} (${VMNAME}) ---"

  # Create the VM from the template
  qm clone ${TEMPLATE_VMID} ${VMID} --name ${VMNAME} --full

  # Configure hardware
  qm resize ${VMID} scsi0 ${DISK_SIZE}
  qm set ${VMID} --cores ${CORES} --memory ${MEMORY}

  # Configure Cloud-Init with user settings first
  qm set ${VMID} --ciuser user --cipassword user
  qm set ${VMID} --sshkeys <(echo "${SSH_PUBLIC_KEY}")
  qm set ${VMID} --ide2 ${STORAGE_NAME}:cloudinit
  
  # Then apply the custom snippet (vendor data to preserve user config)
  qm set ${VMID} --cicustom "vendor=local:snippets/${SNIPPET}"
}


# --- Main Execution ---

# 1. Setup the template
setup_template

# Create cloud-init snippet for WAN passthrough
# This enables IP forwarding and NAT
echo "--- Creating cloud-init snippet for WAN VMs ---"
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p ${SNIPPET_DIR}
SNIPPET_FILE="wan-passthrough.yaml"
SNIPPET_PATH="${SNIPPET_DIR}/${SNIPPET_FILE}"

cat <<'EOF' > ${SNIPPET_PATH}
#cloud-config
# Vendor cloud-init for NAT configuration
# This preserves the user configuration from the main cloud-init

package_update: true
package_upgrade: true
packages:
  - iptables
  - iptables-persistent
  - netfilter-persistent
  - net-tools

write_files:
  - path: /etc/sysctl.d/99-ip-forward.conf
    content: |
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.forwarding=1
      net.ipv4.conf.default.forwarding=1
    permissions: '0644'
  
  - path: /usr/local/bin/setup-nat.sh
    content: |
      #!/bin/bash
      # NAT setup script with interface detection
      
      # Wait for network interfaces to be ready
      sleep 10
      
      # Detect WAN and LAN interfaces
      WAN_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
      if [ -z "$WAN_IF" ]; then
          # Fallback: find first interface with DHCP IP
          WAN_IF=$(ip -o -4 addr show | grep -v "172.0.0.1" | head -n1 | awk '{print $2}')
      fi
      
      # LAN interface is the other one
      ALL_IFS=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|ens)' | grep -v "$WAN_IF")
      LAN_IF=$(echo "$ALL_IFS" | head -n1)
      
      echo "WAN Interface: $WAN_IF" | tee -a /var/log/nat-setup.log
      echo "LAN Interface: $LAN_IF" | tee -a /var/log/nat-setup.log
      
      # Enable IP forwarding
      sysctl -w net.ipv4.ip_forward=1
      sysctl -w net.ipv4.conf.all.forwarding=1
      
      # Clear existing rules
      iptables -t nat -F
      iptables -t nat -X
      iptables -F FORWARD
      
      # Setup NAT rules
      iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
      iptables -A FORWARD -i $LAN_IF -o $WAN_IF -j ACCEPT
      iptables -A FORWARD -i $WAN_IF -o $LAN_IF -m state --state RELATED,ESTABLISHED -j ACCEPT
      
      # Allow all forwarding (less restrictive, for testing)
      iptables -P FORWARD ACCEPT
      
      # Save rules
      netfilter-persistent save
      
      # Log iptables status
      echo "=== IPTables NAT Rules ===" | tee -a /var/log/nat-setup.log
      iptables -t nat -L -n -v | tee -a /var/log/nat-setup.log
      echo "=== IPTables FORWARD Rules ===" | tee -a /var/log/nat-setup.log
      iptables -L FORWARD -n -v | tee -a /var/log/nat-setup.log
      
      exit 0
    permissions: '0755'
  
  - path: /etc/systemd/system/setup-nat.service
    content: |
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
    permissions: '0644'

runcmd:
  # Enable IP forwarding immediately
  - sysctl -w net.ipv4.ip_forward=1
  - sysctl -w net.ipv4.conf.all.forwarding=1
  - sysctl -p /etc/sysctl.d/99-ip-forward.conf
  # Make setup script executable
  - chmod +x /usr/local/bin/setup-nat.sh
  # Enable and start the NAT setup service
  - systemctl daemon-reload
  - systemctl enable setup-nat.service
  - systemctl start setup-nat.service
  # Wait a bit for the service to complete
  - sleep 15
  # Log completion
  - echo "Cloud-init NAT setup completed at $(date)" >> /var/log/nat-setup.log

power_state:
  mode: reboot
  timeout: 300
  condition: true
EOF

echo "Snippet created at ${SNIPPET_PATH}"

# 2. Create VMs
echo "--- Starting VM Creation ---"

# --- VM Definitions ---

# --- VM Group 1 (2 CPU, 2GB RAM, 16GB Disk) ---
COMMON_CORES=2
COMMON_MEMORY=2048
COMMON_DISK="16G"

# VM 1000: wan0
create_wan_vm 1000 "wan0" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK} ${SNIPPET_FILE}
qm set 1000 --net0 virtio,bridge=vmbr00 --ipconfig0 ip=dhcp
qm set 1000 --net1 virtio,bridge=vmbr10 --ipconfig1 ip=172.0.10.1/24
qm set 1000 --net2 virtio,bridge=admin --ipconfig2 ip=126.0.0.10/24
qm set 1000 --nameserver "1.1.1.1 1.0.0.1"

# VM 1001: wan1
create_wan_vm 1001 "wan1" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK} ${SNIPPET_FILE}
qm set 1001 --net0 virtio,bridge=vmbr01 --ipconfig0 ip=dhcp
qm set 1001 --net1 virtio,bridge=vmbr11 --ipconfig1 ip=172.0.11.1/24
qm set 1001 --net2 virtio,bridge=admin --ipconfig2 ip=126.0.0.11/24
qm set 1001 --nameserver "1.1.1.1 1.0.0.1"

# VM 1003: lan0
create_vm 1003 "lan0" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1003 --net0 virtio,bridge=vmbr03 --ipconfig0 ip=dhcp
qm set 1003 --net1 virtio,bridge=admin --ipconfig1 ip=126.0.0.13/24

# VM 1004: lan1
create_vm 1004 "lan1" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1004 --net0 virtio,bridge=vmbr03 --ipconfig0 ip=dhcp
qm set 1004 --net1 virtio,bridge=admin --ipconfig1 ip=126.0.0.14/24

# VM 1005: lan2 (Assuming name lan2 as lan1 is duplicated)
create_vm 1005 "lan2" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1005 --net0 virtio,bridge=vmbr03 --ipconfig0 ip=dhcp
qm set 1005 --net1 virtio,bridge=admin --ipconfig1 ip=126.0.0.15/24


# --- VM Group 2 (8 CPU, 8GB RAM, 32GB Disk) ---

# VM 1002
create_vm 1002 "router" 8 8192 "32G"
qm set 1002 --net0 virtio,bridge=vmbr10 --ipconfig0 ip=172.0.10.10/24,gw=172.0.10.1
qm set 1002 --net1 virtio,bridge=vmbr11 --ipconfig1 ip=172.0.11.10/24,gw=172.0.11.1
qm set 1002 --net2 virtio,bridge=vmbr02 --ipconfig2 ip=10.40.0.1/20
qm set 1002 --net3 virtio,bridge=admin --ipconfig3 ip=126.0.0.12/24
qm set 1002 --nameserver "1.1.1.1 1.0.0.1"


echo "--- All VMs created ---"
echo "NOTE: This script does not start the VMs. You can start them from the Proxmox UI."
echo "IMPORTANT: Review the generated commands and ensure they match your Proxmox environment."
echo ""
echo "=== WAN VM Configuration ==="
echo "wan0 and wan1 are configured as NAT gateways:"
echo "  - net0 (eth0): WAN interface with DHCP (connects to external network)"
echo "  - net1 (eth1): LAN interface (connects to router VM)"
echo "  - IP forwarding and NAT are enabled automatically via cloud-init"
echo "  - VMs will reboot after initial setup to apply all settings"
echo ""
echo "=== Admin Bridge Configuration ==="
echo "All VMs are connected to the 'admin' bridge (126.0.0.0/24) for SSH access from Proxmox:"
echo "  - wan0:   126.0.0.10"
echo "  - wan1:   126.0.0.11"
echo "  - router: 126.0.0.12"
echo "  - lan0:   126.0.0.13"
echo "  - lan1:   126.0.0.14"
echo "  - lan2:   126.0.0.15"
echo "  - Proxmox: 126.0.0.1"
echo ""

read -p "Do you want to start all created VMs now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
  echo "--- Starting all VMs ---"
  for vmid in 1000 1001 1003 1004 1005 1002; do
    echo "Starting VM ${vmid}..."
    qm start "${vmid}"
  done
  echo "--- All VMs started ---"
else
  echo "VMs were not started."
fi
