#!/usr/bin/env bash
#
# kubeconfig.sh - Configure local kubectl to connect to the cluster
#
# Usage:
#   ./kubeconfig.sh [options]
#
# Options:
#   -c, --config FILE    Path to cluster config (default: config/cluster.yaml)
#   -h, --help           Show this help message
#
# This script fetches the kubeconfig from the first control plane node
# and merges it into ~/.kube/config with a context named after the cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"

# Default config
CLUSTER_CONFIG="$PROJECT_DIR/config/cluster.yaml"

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
CLUSTER_NAME=$(yaml_get "$CLUSTER_CONFIG" ".cluster.name" "k8s-cluster")
CP_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.ip_start" "")

# SSH settings (from versions.yaml)
CI_USER="$VM_SSH_USER"
CI_SSH_PUB_KEY_FILE=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.ssh_key_file" "~/.ssh/id_rsa.pub")
CI_SSH_PUB_KEY_FILE=$(expand_path "$CI_SSH_PUB_KEY_FILE")
CI_SSH_KEY="${CI_SSH_PUB_KEY_FILE%.pub}"

if [[ ! -f "$CI_SSH_KEY" ]]; then
    die "SSH private key not found: $CI_SSH_KEY"
fi

# First control plane IP
FIRST_CP_IP="$CP_IP_START"

log_info "Cluster: $CLUSTER_NAME"
log_info "Control plane: $FIRST_CP_IP"

# Fetch kubeconfig from first control plane
TEMP_KUBECONFIG=$(mktemp)
trap "rm -f $TEMP_KUBECONFIG" EXIT

log_info "Fetching kubeconfig from $FIRST_CP_IP..."

scp -o StrictHostKeyChecking=accept-new -i "$CI_SSH_KEY" \
    "${CI_USER}@${FIRST_CP_IP}:~/.kube/config" "$TEMP_KUBECONFIG" || \
    die "Failed to fetch kubeconfig from $FIRST_CP_IP"

# Ensure ~/.kube directory exists
mkdir -p ~/.kube

# Create temp dir for cert files
CERT_DIR=$(mktemp -d)
trap "rm -rf $TEMP_KUBECONFIG $CERT_DIR" EXIT

# Extract certificate data and decode to files
KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$CERT_DIR/ca.crt"
KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > "$CERT_DIR/client.crt"
KUBECONFIG="$TEMP_KUBECONFIG" kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > "$CERT_DIR/client.key"

# Determine server URL
SERVER_URL="https://${FIRST_CP_IP}:6443"

log_info "Configuring context: $CLUSTER_NAME"

# Backup existing config if present
if [[ -f ~/.kube/config ]]; then
    cp ~/.kube/config ~/.kube/config.bak
fi

# Remove old entries for this cluster
kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-user "${CLUSTER_NAME}-admin" 2>/dev/null || true

# Set cluster (--embed-certs embeds the cert data)
kubectl config set-cluster "$CLUSTER_NAME" \
    --server="$SERVER_URL" \
    --certificate-authority="$CERT_DIR/ca.crt" \
    --embed-certs=true

# Set credentials
kubectl config set-credentials "${CLUSTER_NAME}-admin" \
    --client-certificate="$CERT_DIR/client.crt" \
    --client-key="$CERT_DIR/client.key" \
    --embed-certs=true

# Set context
kubectl config set-context "$CLUSTER_NAME" \
    --cluster="$CLUSTER_NAME" \
    --user="${CLUSTER_NAME}-admin"

chmod 600 ~/.kube/config

if [[ -f ~/.kube/config.bak ]]; then
    log_success "Updated kubeconfig (backup: ~/.kube/config.bak)"
else
    log_success "Created ~/.kube/config"
fi

# Set current context
kubectl config use-context "$CLUSTER_NAME"

echo ""
log_success "kubectl configured for cluster: $CLUSTER_NAME"
log_info "Current context: $(kubectl config current-context)"
echo ""

# Test connection
log_info "Testing connection..."
if kubectl cluster-info &>/dev/null; then
    kubectl cluster-info
    echo ""
    log_info "Nodes:"
    kubectl get nodes
else
    log_warn "Could not connect to cluster (may still be initializing)"
fi
