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

# --- Main Execution ---

# 1. Setup the template
setup_template

# Create cloud-init snippet for WAN passthrough
# This enables IP forwarding and NAT
echo "--- Creating cloud-init snippet for WAN VMs ---"
SNIPPET_PATH="/var/lib/vz/snippets/wan-passthrough.yaml"
cat <<'EOF' > ${SNIPPET_PATH}
#cloud-config
# This script enables IP forwarding and NAT to turn the VM into a gateway.
package_update: true
packages:
  - iptables-persistent
runcmd:
  # Enable IP forwarding
  - 'sed -i -e "/^#net.ipv4.ip_forward=1/s/^#//" /etc/sysctl.conf'
  - 'sysctl -p'
  # Add NAT rule
  - 'iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE'
  # Save iptables rules to make them persistent
  - 'sh -c "iptables-save > /etc/iptables/rules.v4"'
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
create_vm 1000 "wan0" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1000 --net0 virtio,bridge=vmbr00 --ipconfig0 ip=dhcp
qm set 1000 --net1 virtio,bridge=vmbr10 --ipconfig1 ip=172.0.10.1/24
qm set 1000 --nameserver "1.1.1.1 1.0.0.1"
qm set 1000 --cicustom user=local:snippets/wan-passthrough.yaml

# VM 1001: wan1
create_vm 1001 "wan1" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1001 --net0 virtio,bridge=vmbr01 --ipconfig0 ip=dhcp
qm set 1001 --net1 virtio,bridge=vmbr11 --ipconfig1 ip=172.0.11.1/24
qm set 1001 --nameserver "1.1.1.1 1.0.0.1"
qm set 1001 --cicustom user=local:snippets/wan-passthrough.yaml

# VM 1003: lan0
create_vm 1003 "lan0" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1003 --net0 virtio,bridge=vmbr03 --ipconfig0 ip=dhcp

# VM 1004: lan1
create_vm 1004 "lan1" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1004 --net0 virtio,bridge=vmbr03 --ipconfig0 ip=dhcp

# VM 1005: lan2 (Assuming name lan2 as lan1 is duplicated)
create_vm 1005 "lan2" ${COMMON_CORES} ${COMMON_MEMORY} ${COMMON_DISK}
qm set 1005 --net0 virtio,bridge=vmbr03 --ipconfig0 ip=dhcp


# --- VM Group 2 (8 CPU, 8GB RAM, 32GB Disk) ---

# VM 1002
create_vm 1002 "router" 8 8192 "32G"
qm set 1002 --net0 virtio,bridge=vmbr10 --ipconfig0 ip=172.0.10.10/24,gw=172.0.10.1
qm set 1002 --net1 virtio,bridge=vmbr11 --ipconfig1 ip=172.0.11.10/24,gw=172.0.11.1
qm set 1002 --net2 virtio,bridge=vmbr12 --ipconfig2 ip=172.0.12.10/24
qm set 1002 --nameserver "1.1.1.1 1.0.0.1"


echo "--- All VMs created ---"
echo "NOTE: This script does not start the VMs. You can start them from the Proxmox UI."
echo "IMPORTANT: Review the generated commands and ensure they match your Proxmox environment."

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
