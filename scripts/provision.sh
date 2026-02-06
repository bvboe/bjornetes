#!/usr/bin/env bash
#
# provision.sh - Provision VMs for Kubernetes cluster using Chainguard images
#
# Usage:
#   ./provision.sh [options]
#
# Options:
#   -c, --config FILE    Path to cluster config (default: config/cluster.yaml)
#   -i, --images FILE    Path to images config (default: config/image-sources.yaml)
#   -n, --dry-run        Show what would be created without making changes
#   -h, --help           Show this help message
#
# VMs boot with DHCP, then are reconfigured with static IPs via SSH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/proxmox.sh"
source "$SCRIPT_DIR/lib/image.sh"

# Default config paths
CLUSTER_CONFIG="$PROJECT_DIR/config/cluster.yaml"
IMAGES_CONFIG="$PROJECT_DIR/config/image-sources.yaml"
DRY_RUN=false

usage() {
    head -17 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CLUSTER_CONFIG="$2"
            shift 2
            ;;
        -i|--images)
            IMAGES_CONFIG="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Validate config files
[[ -f "$CLUSTER_CONFIG" ]] || die "Cluster config not found: $CLUSTER_CONFIG"
[[ -f "$IMAGES_CONFIG" ]] || die "Images config not found: $IMAGES_CONFIG"

# Load component versions from config
load_versions

# Initialize Proxmox connection
pve_init "$CLUSTER_CONFIG"
pve_test_connection || die "Cannot connect to Proxmox"

# Get image source for VMs (control plane and workers use same image)
IMAGE_SOURCE=$(image_for_role "$IMAGES_CONFIG" "control_plane")
IMAGE_NAME=$(image_get_template_name "$IMAGES_CONFIG" "$IMAGE_SOURCE")

# Find the qcow2 image on Proxmox
# Check source-specific import_dir, then defaults, then hardcoded fallback
IMPORT_DIR=$(yaml_get "$IMAGES_CONFIG" ".sources.${IMAGE_SOURCE}.import_dir" "")
if [[ -z "$IMPORT_DIR" ]]; then
    IMPORT_DIR=$(yaml_get "$IMAGES_CONFIG" ".defaults.import_dir" "/mnt/pve/Wall-E-NFS/import")
fi
# Sort by filename (which contains date) to get the latest version
IMAGE_PATH=$(pve_ssh "ls ${IMPORT_DIR}/${IMAGE_NAME}*.qcow2 2>/dev/null | sort -r | head -1")

if [[ -z "$IMAGE_PATH" ]]; then
    die "No qcow2 image found matching '${IMAGE_NAME}' in ${IMPORT_DIR} (run image-sync.sh first)"
fi

log_info "Using image: $IMAGE_PATH"

# Read cluster configuration
CLUSTER_NAME=$(yaml_get "$CLUSTER_CONFIG" ".cluster.name" "k8s-cluster")
VMID_START=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.vmid_start" "200")
STORAGE=$(yaml_get "$CLUSTER_CONFIG" ".proxmox.storage" "local-lvm")
BRIDGE=$(yaml_get "$CLUSTER_CONFIG" ".proxmox.bridge" "vmbr0")

# VM defaults
DEFAULT_CORES=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.cores" "2")
DEFAULT_MEMORY=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.memory" "4096")
DEFAULT_DISK=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.disk_size" "32")

# SSH settings for Chainguard VMs (from versions.yaml)
CG_USER="$VM_SSH_USER"

# Get local SSH public key to inject into VMs
CI_SSH_KEY_FILE=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.ssh_key_file" "~/.ssh/id_rsa.pub")
CI_SSH_KEY_FILE=$(expand_path "$CI_SSH_KEY_FILE")

if [[ -f "$CI_SSH_KEY_FILE" ]]; then
    LOCAL_SSH_KEY=$(cat "$CI_SSH_KEY_FILE")
else
    die "SSH public key not found: $CI_SSH_KEY_FILE"
fi

# Derive private key path from public key path (remove .pub suffix)
CI_SSH_PRIVATE_KEY="${CI_SSH_KEY_FILE%.pub}"
if [[ ! -f "$CI_SSH_PRIVATE_KEY" ]]; then
    die "SSH private key not found: $CI_SSH_PRIVATE_KEY"
fi

# Network settings
NET_GATEWAY=$(yaml_get "$CLUSTER_CONFIG" ".network.gateway" "")
NET_NAMESERVER=$(yaml_get "$CLUSTER_CONFIG" ".network.nameserver" "")
NET_CIDR=$(yaml_get "$CLUSTER_CONFIG" ".network.cidr" "/24")

# Control plane settings
CP_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.count" "3")
CP_NAME_PATTERN=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.name_pattern" "cp-{index}")
CP_CORES=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.cores" "$DEFAULT_CORES")
CP_MEMORY=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.memory" "$DEFAULT_MEMORY")
CP_DISK=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.disk_size" "$DEFAULT_DISK")
CP_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.ip_start" "")

# Worker settings
WORKER_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.count" "3")
WORKER_NAME_PATTERN=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.name_pattern" "worker-{index}")
WORKER_CORES=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.cores" "$DEFAULT_CORES")
WORKER_MEMORY=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.memory" "$DEFAULT_MEMORY")
WORKER_DISK=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.disk_size" "$DEFAULT_DISK")
WORKER_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.ip_start" "")

log_info "Cluster: $CLUSTER_NAME"
log_info "Control Plane: $CP_COUNT nodes"
log_info "Workers: $WORKER_COUNT nodes"
log_info "Image: $(basename "$IMAGE_PATH")"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN - No changes will be made"
    echo ""
fi

# Arrays to track created VMs for post-boot configuration
declare -a VM_IDS=()
declare -a VM_NAMES=()
declare -a VM_IPS=()

# Create a single VM (Phase 1: create and start)
create_vm() {
    local vmid="$1"
    local name="$2"
    local cores="$3"
    local memory="$4"
    local disk_size="$5"
    local static_ip="$6"

    if pve_vmid_exists "$vmid"; then
        log_warn "VMID $vmid already exists, skipping..."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create VM $vmid ($name)"
        log_info "  Cores: $cores, Memory: ${memory}MB, Disk: ${disk_size}GB"
        log_info "  Static IP: $static_ip (configured post-boot)"
        return 0
    fi

    log_info "Creating VM $vmid ($name)..."

    # Create VM with SMBIOS config (pass local SSH key)
    pve_create_vm_smbios "$vmid" "$name" "$cores" "$memory" "$STORAGE" "$BRIDGE" "$LOCAL_SSH_KEY"

    # Import and configure disk
    pve_setup_chainguard_disk "$vmid" "$IMAGE_PATH" "$STORAGE" "$disk_size"

    # Start VM
    pve_start_vm "$vmid"

    # Track for post-boot configuration
    VM_IDS+=("$vmid")
    VM_NAMES+=("$name")
    VM_IPS+=("$static_ip")

    log_success "VM $vmid ($name) created and started"
}

# Configure VM network (Phase 2: post-boot configuration)
configure_vm_network() {
    local vmid="$1"
    local name="$2"
    local static_ip="$3"

    log_info "Configuring network for VM $vmid ($name) -> $static_ip..."

    # Get DHCP IP for this VM (scan from Proxmox)
    local dhcp_ip
    dhcp_ip=$(pve_get_vm_dhcp_ip "$vmid" 90) || {
        log_error "Could not find DHCP IP for VM $vmid"
        return 1
    }
    log_info "VM $vmid has DHCP IP: $dhcp_ip"

    # Remove any stale known_hosts entry for this DHCP IP
    # DHCP IPs get reused, so old host keys cause SSH to fail
    ssh-keygen -R "$dhcp_ip" &>/dev/null || true

    # Wait for SSH to be ready (direct connection from local machine)
    # Chainguard VMs can take a while to boot, especially on first boot
    log_info "Waiting for SSH access to $dhcp_ip..."
    local elapsed=0
    while [[ $elapsed -lt 300 ]]; do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$CI_SSH_PRIVATE_KEY" "${CG_USER}@${dhcp_ip}" 'echo ok' &>/dev/null; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [[ $elapsed -ge 300 ]]; then
        log_error "SSH not accessible for VM $vmid at $dhcp_ip after 5 minutes"
        return 1
    fi

    # Configure static IP and hostname via direct SSH
    configure_vm_network_direct "$dhcp_ip" "$CG_USER" "$name" "$static_ip" "$NET_GATEWAY" "$NET_NAMESERVER" "ens18" "$CI_SSH_PRIVATE_KEY"

    log_success "VM $vmid configured with static IP $static_ip"
}

# Phase 1: Create all VMs
log_info "Phase 1: Creating VMs..."
echo ""

vmid=$VMID_START

# Create control plane nodes
log_info "Creating control plane nodes..."
for ((i = 0; i < CP_COUNT; i++)); do
    name=$(generate_name "$CP_NAME_PATTERN" "$i")
    static_ip="$(ip_add_offset "$CP_IP_START" "$i")${NET_CIDR}"
    create_vm "$vmid" "$name" "$CP_CORES" "$CP_MEMORY" "$CP_DISK" "$static_ip"
    vmid=$((vmid + 1))
done

echo ""

# Create worker nodes
log_info "Creating worker nodes..."
for ((i = 0; i < WORKER_COUNT; i++)); do
    name=$(generate_name "$WORKER_NAME_PATTERN" "$i")
    static_ip="$(ip_add_offset "$WORKER_IP_START" "$i")${NET_CIDR}"
    create_vm "$vmid" "$name" "$WORKER_CORES" "$WORKER_MEMORY" "$WORKER_DISK" "$static_ip"
    vmid=$((vmid + 1))
done

echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_success "Dry run complete!"
    exit 0
fi

# Phase 2: Wait for all VMs to boot and configure networking
if [[ ${#VM_IDS[@]} -gt 0 ]]; then
    log_info "Phase 2: Configuring VM networking (waiting for boot)..."
    echo ""

    # Wait a bit for VMs to boot and get DHCP
    log_info "Waiting for VMs to boot and obtain DHCP leases..."
    sleep 60

    for ((i = 0; i < ${#VM_IDS[@]}; i++)); do
        configure_vm_network "${VM_IDS[$i]}" "${VM_NAMES[$i]}" "${VM_IPS[$i]}" || {
            log_warn "Failed to configure VM ${VM_IDS[$i]}, manual configuration required"
        }
    done
fi

echo ""
log_success "Provisioning complete!"

log_info "Next steps:"
log_info "  1. Verify SSH access: ssh ${CG_USER}@<node-ip>"
log_info "  2. Run bootstrap.sh to initialize Kubernetes"
