#!/usr/bin/env bash
# Proxmox operations via SSH

# Requires common.sh to be sourced first

# Global connection settings (set by pve_init)
PVE_HOST=""
PVE_USER=""
PVE_PORT=""
PVE_SSH_KEY=""
PVE_SSH_OPTS=""   # Common options (without port)
PVE_SSH_PORT_OPT=""  # Port option for ssh (-p)
PVE_SCP_PORT_OPT=""  # Port option for scp (-P)

# Initialize Proxmox connection settings from config
pve_init() {
    local config_file="$1"

    PVE_HOST=$(yaml_get "$config_file" ".proxmox.host" "")
    PVE_USER=$(yaml_get "$config_file" ".proxmox.user" "root")
    PVE_PORT=$(yaml_get "$config_file" ".proxmox.port" "22")
    PVE_SSH_KEY=$(yaml_get "$config_file" ".proxmox.ssh_key" "~/.ssh/id_rsa")
    PVE_SSH_KEY=$(expand_path "$PVE_SSH_KEY")

    if [[ -z "$PVE_HOST" ]]; then
        die "Proxmox host not configured in $config_file"
    fi

    # Build SSH options (common, without port)
    PVE_SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    if [[ -f "$PVE_SSH_KEY" ]]; then
        PVE_SSH_OPTS="$PVE_SSH_OPTS -i $PVE_SSH_KEY"
    fi

    # Port options differ between ssh and scp
    PVE_SSH_PORT_OPT="-p $PVE_PORT"
    PVE_SCP_PORT_OPT="-P $PVE_PORT"

    log_info "Proxmox connection: ${PVE_USER}@${PVE_HOST}:${PVE_PORT}"
}

# Execute command on Proxmox host
pve_ssh() {
    # shellcheck disable=SC2086
    ssh $PVE_SSH_OPTS $PVE_SSH_PORT_OPT "${PVE_USER}@${PVE_HOST}" "$@"
}

# Copy file to Proxmox host
pve_scp_to() {
    local local_path="$1"
    local remote_path="$2"
    # shellcheck disable=SC2086
    scp $PVE_SSH_OPTS $PVE_SCP_PORT_OPT "$local_path" "${PVE_USER}@${PVE_HOST}:${remote_path}"
}

# Test connection to Proxmox
pve_test_connection() {
    log_info "Testing connection to Proxmox..."
    if pve_ssh "pveversion" &>/dev/null; then
        local version
        version=$(pve_ssh "pveversion")
        log_success "Connected to Proxmox: $version"
        return 0
    else
        log_error "Failed to connect to Proxmox"
        return 1
    fi
}

# Check if storage exists
pve_storage_exists() {
    local storage="$1"
    pve_ssh "pvesm status" | grep -q "^${storage}[[:space:]]"
}

# Check if VMID is in use
pve_vmid_exists() {
    local vmid="$1"
    pve_ssh "qm status $vmid" &>/dev/null
}

# List VMs/templates matching a name pattern (glob-style)
# Returns: VMID NAME (one per line, sorted by name for version ordering)
pve_list_vms_by_pattern() {
    local pattern="$1"
    pve_ssh "qm list" | tail -n +2 | awk '{print $1, $2}' | while read -r vmid name; do
        # Convert glob pattern to regex (simple * -> .*)
        local regex="^${pattern//\*/.*}$"
        if [[ "$name" =~ $regex ]]; then
            echo "$vmid $name"
        fi
    done | sort -k2
}

# Get VM status
pve_vm_status() {
    local vmid="$1"
    pve_ssh "qm status $vmid" 2>/dev/null | awk '{print $2}'
}

# Create VM from template/image (configured for Chainguard VMs with UEFI)
# Note: EFI disk should be added AFTER the boot disk is attached
pve_create_vm() {
    local vmid="$1"
    local name="$2"
    local cores="$3"
    local memory="$4"
    local storage="$5"
    local disk_size="$6"
    local bridge="$7"

    log_info "Creating VM $vmid ($name)..."

    pve_ssh "qm create $vmid \
        --name '$name' \
        --cores $cores \
        --memory $memory \
        --net0 virtio,bridge=$bridge \
        --bios ovmf \
        --machine q35 \
        --ostype l26 \
        --scsihw virtio-scsi-single \
        --cpu x86-64-v2-AES"

    log_success "VM $vmid created"
}

# Add EFI disk to VM (call after boot disk is attached)
pve_add_efidisk() {
    local vmid="$1"
    local storage="$2"

    log_info "Adding EFI disk to VM $vmid..."
    pve_ssh "qm set $vmid --efidisk0 ${storage}:1,format=raw,efitype=4m"
    log_success "EFI disk added"
}

# Start VM
pve_start_vm() {
    local vmid="$1"

    log_info "Starting VM $vmid..."
    pve_ssh "qm start $vmid"
    log_success "VM $vmid started"
}

# Stop VM
pve_stop_vm() {
    local vmid="$1"

    log_info "Stopping VM $vmid..."
    pve_ssh "qm stop $vmid"
    log_success "VM $vmid stopped"
}

# Delete VM
pve_delete_vm() {
    local vmid="$1"
    local purge="${2:-true}"

    log_info "Deleting VM $vmid..."

    # Stop if running
    local status
    status=$(pve_vm_status "$vmid")
    if [[ "$status" == "running" ]]; then
        pve_stop_vm "$vmid"
        sleep 2
    fi

    if [[ "$purge" == "true" ]]; then
        pve_ssh "qm destroy $vmid --purge"
    else
        pve_ssh "qm destroy $vmid"
    fi

    log_success "VM $vmid deleted"
}

# Convert VM to template
pve_convert_to_template() {
    local vmid="$1"

    log_info "Converting VM $vmid to template..."
    pve_ssh "qm template $vmid"
    log_success "VM $vmid is now a template"
}

# Create VM with SMBIOS configuration (for Chainguard VMs)
pve_create_vm_smbios() {
    local vmid="$1"
    local name="$2"
    local cores="$3"
    local memory="$4"
    local storage="$5"
    local bridge="$6"
    local ssh_pubkey="$7"

    log_info "Creating VM $vmid ($name) with SMBIOS config..."

    # Create VM with UEFI settings for Chainguard
    pve_ssh "qm create $vmid \
        --name '$name' \
        --cores $cores \
        --memory $memory \
        --net0 virtio,bridge=$bridge \
        --bios ovmf \
        --machine q35 \
        --ostype l26 \
        --scsihw virtio-scsi-single \
        --cpu x86-64-v2-AES"

    # Configure SMBIOS with SSH key (Chainguard reads from type 11 OEM strings)
    pve_ssh "qm set $vmid --args \"-smbios type=1,product=cgr.dev/qemu/v1 -smbios type=11,value=\\\"cgr.dev/qemu/v1/ssh-pubkey=${ssh_pubkey}\\\"\""

    log_success "VM $vmid created with SMBIOS"
}

# Import disk and configure for Chainguard VM
pve_setup_chainguard_disk() {
    local vmid="$1"
    local image_path="$2"
    local storage="$3"
    local disk_size="$4"

    log_info "Importing disk for VM $vmid..."

    # Import disk from qcow2
    pve_ssh "qm importdisk $vmid '$image_path' $storage"

    # Get the imported disk reference from unused0
    # Format varies by storage type: LVM uses "vm-ID-disk-0", directory uses "ID/vm-ID-disk-0.raw"
    local disk_ref
    disk_ref=$(pve_ssh "qm config $vmid | grep '^unused0:' | sed 's/unused0: //'")

    # Attach disk as scsi0 with iothread
    pve_ssh "qm set $vmid --scsi0 ${disk_ref},iothread=1 --boot order=scsi0"

    # Add EFI disk
    pve_ssh "qm set $vmid --efidisk0 ${storage}:1,format=raw,efitype=4m"

    # Resize disk if larger than base
    if [[ "$disk_size" -gt 3 ]]; then
        local expand_size=$((disk_size - 3))
        pve_ssh "qm disk resize $vmid scsi0 +${expand_size}G"
    fi

    log_success "Disk configured for VM $vmid"
}

# Configure VM network via SSH (post-boot configuration)
# Sets static IP and hostname on a Chainguard VM
# This SSHes directly from the local machine to the VM
configure_vm_network_direct() {
    local dhcp_ip="$1"      # Current DHCP IP address
    local user="$2"         # SSH user (usually 'linky')
    local new_hostname="$3"
    local static_ip="$4"
    local gateway="$5"
    local nameserver="$6"
    local interface="${7:-ens18}"
    local ssh_key="${8:-}"  # SSH private key path

    log_info "Configuring network on $dhcp_ip -> $new_hostname ($static_ip)..."

    # Build SSH options
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
    if [[ -n "$ssh_key" ]]; then
        ssh_opts="$ssh_opts -i $ssh_key"
    fi

    # Create systemd-networkd config for static IP
    local network_config="[Match]
Name=${interface}

[Network]
Address=${static_ip}
Gateway=${gateway}
DNS=${nameserver}"

    # Apply configuration via direct SSH (from local machine)
    # shellcheck disable=SC2086
    ssh $ssh_opts "${user}@${dhcp_ip}" "sudo tee /etc/systemd/network/10-static.network > /dev/null" <<< "$network_config"

    # Set hostname
    # shellcheck disable=SC2086
    ssh $ssh_opts "${user}@${dhcp_ip}" "sudo hostnamectl set-hostname ${new_hostname}"

    # Restart networkd to apply changes (connection will drop as IP changes)
    # shellcheck disable=SC2086
    ssh $ssh_opts "${user}@${dhcp_ip}" "sudo systemctl restart systemd-networkd" &>/dev/null || true

    log_success "Network configured for $new_hostname ($static_ip)"
}

# Get DHCP IP for a VM by MAC address (uses nmap scan)
pve_get_vm_dhcp_ip() {
    local vmid="$1"
    local timeout="${2:-90}"
    local network="${3:-192.168.2.0/24}"
    local elapsed=0

    # Get MAC address from VM config (compatible with BSD and GNU grep)
    local mac
    mac=$(pve_ssh "qm config $vmid | grep 'virtio=' | sed 's/.*virtio=\([A-Fa-f0-9:]*\).*/\1/' | head -1")

    # Log to stderr to avoid polluting stdout (this function returns IP via echo)
    log_info "Looking for DHCP IP for VM $vmid (MAC: $mac)..." >&2

    while [[ $elapsed -lt $timeout ]]; do
        # Use nmap to scan network and find IP by MAC
        local ip
        ip=$(pve_ssh "nmap -sn $network 2>/dev/null | grep -B2 -i '$mac' | grep 'Nmap scan report' | sed 's/.*for \([0-9.]*\).*/\1/' | grep -v '[a-zA-Z]' | head -1")

        # If that didn't work, try extracting from parentheses format
        if [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip=$(pve_ssh "nmap -sn $network 2>/dev/null | grep -B2 -i '$mac' | grep 'Nmap scan report' | sed 's/.*(\([0-9.]*\)).*/\1/' | head -1")
        fi

        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi

        sleep 10
        elapsed=$((elapsed + 10))
    done

    return 1
}
