#!/usr/bin/env bash
#
# destroy.sh - Destroy Kubernetes cluster VMs
#
# Usage:
#   ./destroy.sh [options]
#
# Options:
#   -c, --config FILE    Path to cluster config (default: config/cluster.yaml)
#   -n, --dry-run        Show what would be destroyed without making changes
#   -y, --yes            Skip confirmation prompt
#   -h, --help           Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/proxmox.sh"

# Default config
CLUSTER_CONFIG="$PROJECT_DIR/config/cluster.yaml"
DRY_RUN=false
SKIP_CONFIRM=false

usage() {
    head -14 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CLUSTER_CONFIG="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
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

[[ -f "$CLUSTER_CONFIG" ]] || die "Cluster config not found: $CLUSTER_CONFIG"

# Initialize Proxmox connection
pve_init "$CLUSTER_CONFIG"
pve_test_connection || die "Cannot connect to Proxmox"

# Read cluster configuration
CLUSTER_NAME=$(yaml_get "$CLUSTER_CONFIG" ".cluster.name" "k8s-cluster")
VMID_START=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.vmid_start" "200")
CP_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.count" "3")
WORKER_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.count" "3")
CP_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.ip_start" "")
WORKER_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.ip_start" "")

# Calculate total VMs
TOTAL_VMS=$((CP_COUNT + WORKER_COUNT))

log_info "Cluster: $CLUSTER_NAME"
log_info "VMID range: $VMID_START - $((VMID_START + TOTAL_VMS - 1))"
log_info "VMs to destroy: $TOTAL_VMS ($CP_COUNT control plane + $WORKER_COUNT workers)"
echo ""

# Collect VMs to destroy
declare -a VMS_TO_DESTROY=()

for ((i = 0; i < TOTAL_VMS; i++)); do
    vmid=$((VMID_START + i))
    if pve_vmid_exists "$vmid"; then
        name=$(pve_ssh "qm config $vmid --current | grep '^name:' | cut -d' ' -f2")
        status=$(pve_vm_status "$vmid")
        VMS_TO_DESTROY+=("$vmid:$name:$status")
        log_info "  Found: VM $vmid ($name) - $status"
    fi
done

if [[ ${#VMS_TO_DESTROY[@]} -eq 0 ]]; then
    log_warn "No VMs found to destroy"
    exit 0
fi

echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN - Would destroy ${#VMS_TO_DESTROY[@]} VMs:"
    for vm_info in "${VMS_TO_DESTROY[@]}"; do
        IFS=':' read -r vmid name status <<< "$vm_info"
        log_info "  Would destroy: VM $vmid ($name)"
    done
    exit 0
fi

# Confirmation
if [[ "$SKIP_CONFIRM" != "true" ]]; then
    log_warn "This will PERMANENTLY DELETE ${#VMS_TO_DESTROY[@]} VMs!"
    read -p "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Aborted"
        exit 1
    fi
fi

echo ""

# Delete VMs
for vm_info in "${VMS_TO_DESTROY[@]}"; do
    IFS=':' read -r vmid name status <<< "$vm_info"
    pve_delete_vm "$vmid"
done

# Clean up SSH known_hosts entries for destroyed VMs
log_info "Cleaning up SSH known_hosts entries..."
for ((i = 0; i < CP_COUNT; i++)); do
    ip=$(ip_add_offset "$CP_IP_START" "$i")
    ssh-keygen -R "$ip" 2>/dev/null || true
done
for ((i = 0; i < WORKER_COUNT; i++)); do
    ip=$(ip_add_offset "$WORKER_IP_START" "$i")
    ssh-keygen -R "$ip" 2>/dev/null || true
done
log_success "SSH known_hosts cleaned up"

# Clean up local kubeconfig
if [[ -f "$PROJECT_DIR/kubeconfig" ]]; then
    rm -f "$PROJECT_DIR/kubeconfig"
    log_info "Removed local kubeconfig"
fi

echo ""
log_success "Cluster destroyed successfully!"
