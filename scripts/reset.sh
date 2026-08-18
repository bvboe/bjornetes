#!/usr/bin/env bash
#
# reset.sh - Reset Kubernetes cluster without destroying VMs
#
# Usage:
#   ./reset.sh [options]
#
# Options:
#   -c, --config FILE    Path to cluster config (default: config/cluster.yaml)
#   -h, --help           Show this help message
#
# This script runs kubeadm reset on all nodes and cleans up CNI/kubelet state,
# leaving VMs ready for a fresh bootstrap.sh run.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"

# Default config
CLUSTER_CONFIG="$PROJECT_DIR/config/cluster.yaml"

usage() {
    head -16 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CLUSTER_CONFIG="$2"
            shift 2
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

# Load component versions from config
load_versions

# Read cluster configuration
CP_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.count" "1")
WORKER_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.count" "3")

# SSH settings (from versions.yaml)
CI_USER="$VM_SSH_USER"
CI_SSH_PUB_KEY_FILE=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.ssh_key_file" "~/.ssh/id_rsa.pub")
CI_SSH_PUB_KEY_FILE=$(expand_path "$CI_SSH_PUB_KEY_FILE")
CI_SSH_KEY="${CI_SSH_PUB_KEY_FILE%.pub}"
[[ -f "$CI_SSH_KEY" ]] || die "SSH private key not found: $CI_SSH_KEY"

# Network settings
CP_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.ip_start" "")
WORKER_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.ip_start" "")

[[ -n "$CP_IP_START" ]] || die "Control plane IP start not configured"
[[ -n "$WORKER_IP_START" ]] || die "Worker IP start not configured"

# Calculate IPs
CP_IPS=()
for ((i = 0; i < CP_COUNT; i++)); do
    CP_IPS+=("$(ip_add_offset "$CP_IP_START" "$i")")
done

WORKER_IPS=()
for ((i = 0; i < WORKER_COUNT; i++)); do
    WORKER_IPS+=("$(ip_add_offset "$WORKER_IP_START" "$i")")
done

# SSH helper
vm_ssh() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "$CI_SSH_KEY" "${CI_USER}@${ip}" "$@"
}

# Reset a single node
reset_node() {
    local ip="$1"
    local name="$2"

    log_info "Resetting $name ($ip)..."

    # Check if node is reachable
    if ! vm_ssh "$ip" "true" 2>/dev/null; then
        log_warn "  Cannot reach $name, skipping"
        return 0
    fi

    # Run kubeadm reset
    vm_ssh "$ip" "sudo kubeadm reset -f 2>/dev/null || true"

    # Clean up CNI
    vm_ssh "$ip" "sudo rm -rf /etc/cni/net.d/* 2>/dev/null || true"
    vm_ssh "$ip" "sudo rm -rf /var/lib/cni/* 2>/dev/null || true"
    vm_ssh "$ip" "sudo rm -rf /var/lib/calico/* 2>/dev/null || true"

    # Clean up kubelet
    vm_ssh "$ip" "sudo rm -rf /var/lib/kubelet/* 2>/dev/null || true"
    vm_ssh "$ip" "sudo rm -rf /etc/kubernetes/* 2>/dev/null || true"

    # Clean up etcd data (control plane only)
    vm_ssh "$ip" "sudo rm -rf /var/lib/etcd/* 2>/dev/null || true"

    # Reset iptables rules added by kube-proxy/calico
    vm_ssh "$ip" "sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X 2>/dev/null || true"

    # Stop kubelet if running. bootstrap.sh installs kubelet as a systemd unit,
    # so the OpenRC call alone was a no-op and left the kubelet running against
    # the state this script just deleted.
    vm_ssh "$ip" "sudo systemctl stop kubelet 2>/dev/null || sudo rc-service kubelet stop 2>/dev/null || true"

    log_success "  $name reset complete"
}

echo ""
log_info "Resetting Kubernetes cluster..."
echo ""

# Reset workers first
for ((i = 0; i < WORKER_COUNT; i++)); do
    reset_node "${WORKER_IPS[$i]}" "worker-$i"
done

# Then reset control plane
for ((i = 0; i < CP_COUNT; i++)); do
    reset_node "${CP_IPS[$i]}" "cp-$i"
done

# Remove local kubeconfig
if [[ -f "$PROJECT_DIR/kubeconfig" ]]; then
    rm -f "$PROJECT_DIR/kubeconfig"
    log_info "Removed local kubeconfig"
fi

echo ""
log_success "Cluster reset complete. Run ./scripts/bootstrap.sh to reinitialize."
