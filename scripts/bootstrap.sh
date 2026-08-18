#!/usr/bin/env bash
#
# bootstrap.sh - Initialize Kubernetes cluster with kubeadm (single control plane)
#
# Usage:
#   ./bootstrap.sh [options]
#
# Options:
#   -c, --config FILE    Path to cluster config (default: config/cluster.yaml)
#   -h, --help           Show this help message
#
# Prerequisites:
#   - VMs must be provisioned and running (see provision.sh)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"

# Default config
CLUSTER_CONFIG="$PROJECT_DIR/config/cluster.yaml"

usage() {
    head -15 "$0" | grep "^#" | cut -c 3-
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
K8S_VERSION=$(yaml_get "$CLUSTER_CONFIG" ".cluster.kubernetes_version" "1.31")
POD_CIDR=$(yaml_get "$CLUSTER_CONFIG" ".cluster.pod_cidr" "10.244.0.0/16")
SERVICE_CIDR=$(yaml_get "$CLUSTER_CONFIG" ".cluster.service_cidr" "10.96.0.0/12")
USE_PRIVATE_APK=$(yaml_get "$CLUSTER_CONFIG" ".cluster.use_private_apk" "false")

CP_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.count" "1")
WORKER_COUNT=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.count" "3")

# Generate Chainguard APK token if using private repo
APK_TOKEN=""
if [[ "$USE_PRIVATE_APK" == "true" ]]; then
    log_info "Private APK repository enabled, generating auth token..."
    if ! command -v chainctl &>/dev/null; then
        die "chainctl is required for private APK repository but not found. Install from https://edu.chainguard.dev/chainguard/administration/how-to-install-chainctl/"
    fi
    APK_TOKEN=$(chainctl auth token --audience apk.cgr.dev 2>/dev/null) || die "Failed to get chainctl auth token. Run 'chainctl auth login' first."
    log_success "Auth token generated"
fi

# SSH user for Chainguard VMs (from versions.yaml)
CI_USER="$VM_SSH_USER"
CI_SSH_PUB_KEY_FILE=$(yaml_get "$CLUSTER_CONFIG" ".vm_defaults.ssh_key_file" "~/.ssh/id_rsa.pub")
CI_SSH_PUB_KEY_FILE=$(expand_path "$CI_SSH_PUB_KEY_FILE")
CI_SSH_KEY="${CI_SSH_PUB_KEY_FILE%.pub}"
[[ -f "$CI_SSH_KEY" ]] || die "SSH private key not found: $CI_SSH_KEY"

# Network settings
CP_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.control_plane.ip_start" "")
WORKER_IP_START=$(yaml_get "$CLUSTER_CONFIG" ".nodes.workers.ip_start" "")

log_info "Cluster: $CLUSTER_NAME"
log_info "Kubernetes version: $K8S_VERSION"
log_info "Control plane: $CP_COUNT node(s)"
log_info "Workers: $WORKER_COUNT node(s)"
if [[ "$USE_PRIVATE_APK" == "true" ]]; then
    log_info "APK repository: private (chainguard-private)"
else
    log_info "APK repository: public"
fi
echo ""

# SSH to a VM by IP
vm_ssh() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -i "$CI_SSH_KEY" "${CI_USER}@${ip}" "$@"
}

# Collect VM IPs
CP_IPS=()
WORKER_IPS=()

for ((i = 0; i < CP_COUNT; i++)); do
    CP_IPS+=("$(ip_add_offset "$CP_IP_START" "$i")")
done
for ((i = 0; i < WORKER_COUNT; i++)); do
    WORKER_IPS+=("$(ip_add_offset "$WORKER_IP_START" "$i")")
done

log_info "Control plane IPs: ${CP_IPS[*]}"
log_info "Worker IPs: ${WORKER_IPS[*]}"
echo ""

# Chainguard image configuration (loaded from versions.yaml via load_versions)
# CG_REGISTRY and CG_K8S_TAG are set by load_versions()

# Restart containerd so it picks up any config changes before kubeadm runs.
#
# The sandbox (pause) image itself needs nothing here: containerd resolves it
# when it creates the first sandbox, which happens after prepare_k8s_images has
# retagged the Chainguard pause onto the reference containerd asks for.
configure_containerd() {
    local ip="$1"
    log_info "Configuring containerd on $ip..."

    vm_ssh "$ip" "sudo systemctl restart containerd"

    log_success "Containerd configured on $ip"
}

KUBEADM_CONFIG_PATH="/tmp/kubeadm-config.yaml"

# Write the kubeadm config that `kubeadm init` runs from.
#
# etcd and CoreDNS are handled here rather than by retagging. kubeadm builds those
# two references as <imageRepository>/etcd:<tag> and <imageRepository>/coredns:<tag>
# (see GetEtcdImage/GetDNSImage in cmd/kubeadm/app/images/images.go), which is
# exactly how Chainguard names them — so pointing kubeadm straight at the
# Chainguard registry makes the manifest reference the real image instead of a
# registry.k8s.io name with something else behind it.
#
# Leave a version at "kubeadm" to keep its pinned version, which is then mirrored
# by prepare_k8s_images the same way the kube-* images are.
write_kubeadm_config() {
    local ip="$1"

    local etcd_block=""
    local dns_block=""

    if [[ "$ETCD_VERSION" == "kubeadm" ]]; then
        log_info "etcd: using the version kubeadm pins"
    else
        log_warn "etcd: overriding kubeadm's pin with ${CG_REGISTRY}/etcd:${ETCD_VERSION}"
        etcd_block=$(printf 'etcd:\n  local:\n    imageRepository: %s\n    imageTag: %s' \
            "$CG_REGISTRY" "$ETCD_VERSION")
    fi

    if [[ "$COREDNS_VERSION" == "kubeadm" ]]; then
        log_info "CoreDNS: using the version kubeadm pins"
    else
        log_warn "CoreDNS: overriding kubeadm's pin with ${CG_REGISTRY}/coredns:${COREDNS_VERSION}"
        dns_block=$(printf 'dns:\n  imageRepository: %s\n  imageTag: %s' \
            "$CG_REGISTRY" "$COREDNS_VERSION")
    fi

    vm_ssh "$ip" "cat > $KUBEADM_CONFIG_PATH" << EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${ip}
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${KUBEADM_VERSION}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
${etcd_block}
${dns_block}
EOF

    log_success "kubeadm config written to ${ip}:${KUBEADM_CONFIG_PATH}"
}

# Ask kubeadm which images this cluster needs, given the config above.
#
# Reading the list from kubeadm rather than from a hardcoded table is what keeps
# the mirror honest: kubeadm's etcd and CoreDNS pins move with the Kubernetes
# minor, and a stale entry is invisible — the pull succeeds, the retag names an
# image kubeadm never requests, and kubeadm pulls the upstream Debian-based image.
K8S_IMAGES=()
resolve_k8s_images() {
    local ip="$1"

    local image_list
    image_list=$(vm_ssh "$ip" "kubeadm config images list --config $KUBEADM_CONFIG_PATH") \
        || die "Could not read the required image list from kubeadm on $ip"

    # Collect first, then act: vm_ssh reads stdin, so calling it inside a
    # `while read` loop fed by this list would swallow the remaining lines.
    local line
    while IFS= read -r line; do
        # An `x && y` as the last command in the body would take set -e down
        # with it on a blank line, mid-bootstrap and without a message
        if [[ -n "$line" ]]; then
            K8S_IMAGES+=("$line")
        fi
    done <<< "$image_list"
    [[ ${#K8S_IMAGES[@]} -gt 0 ]] || die "kubeadm on $ip reported no required images"

    log_info "Images required by kubeadm:"
    local img
    for img in "${K8S_IMAGES[@]}"; do
        printf "    %s\n" "$img"
    done
}

# Pull the Chainguard images and, where kubeadm insists on a registry.k8s.io
# reference, tag them onto it.
prepare_k8s_images() {
    local ip="$1"

    log_info "Preparing Kubernetes images on $ip..."

    local failed=()
    local unmirrored=()
    local dst src
    for dst in "${K8S_IMAGES[@]}"; do
        # Already pointing at Chainguard (the etcd/CoreDNS overrides): the
        # reference needs no retag, just a pre-pull so the kubelet finds it.
        if [[ "$dst" == "${CG_REGISTRY}"/* ]]; then
            if vm_ssh "$ip" "sudo ctr -n k8s.io images pull '${dst}'"; then
                log_success "  $dst"
            else
                failed+=("$dst")
            fi
            continue
        fi

        src=$(cg_image_for "$dst")
        if [[ -z "$src" ]]; then
            unmirrored+=("$dst")
            continue
        fi

        if vm_ssh "$ip" "sudo ctr -n k8s.io images pull '${src}' && sudo ctr -n k8s.io images tag --force '${src}' '${dst}'"; then
            log_success "  $dst <- $src"
        else
            failed+=("$dst <- $src")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Could not mirror Chainguard images onto the tags kubeadm requires:"
        for dst in "${failed[@]}"; do
            log_error "  $dst"
        done
        die "Refusing to continue: kubeadm would pull these from registry.k8s.io instead. Run ./scripts/check-versions.sh to see which Chainguard tags are available."
    fi

    if [[ ${#unmirrored[@]} -gt 0 ]]; then
        for dst in "${unmirrored[@]}"; do
            log_warn "  No Chainguard mirror for $dst - will be pulled from upstream"
        done
    fi

    log_success "Kubernetes images prepared on $ip"
}

# Verify SSH access
log_info "Verifying SSH access to all nodes..."
for ip in "${CP_IPS[@]}" "${WORKER_IPS[@]}"; do
    if ! vm_ssh "$ip" "true" 2>/dev/null; then
        die "Cannot SSH to $ip"
    fi
    log_success "  $ip - OK"
done
echo ""

# Configure private APK repository on a node
setup_private_apk() {
    local ip="$1"
    local token="$2"

    log_info "Configuring private APK repository on $ip..."

    # Install apko to get the signing keys
    vm_ssh "$ip" "sudo apk add apko"

    # Configure public repositories first (before install-keys)
    vm_ssh "$ip" 'echo "https://apk.cgr.dev/chainguard" | sudo tee /etc/apk/repositories > /dev/null
echo "https://apk.cgr.dev/extra-packages" | sudo tee -a /etc/apk/repositories > /dev/null'

    # Install signing keys (for public repos only)
    vm_ssh "$ip" "sudo apko install-keys"

    # Now add the private repository
    vm_ssh "$ip" 'echo "https://apk.cgr.dev/chainguard-private" | sudo tee -a /etc/apk/repositories > /dev/null'

    # Write token to file for authenticated commands
    echo "export HTTP_AUTH=\"basic::user:${token}\"" | vm_ssh "$ip" "cat > /tmp/apk-auth.env"

    # Configure HTTP_AUTH for apk (persistent via /etc/profile.d)
    vm_ssh "$ip" "sudo mv /tmp/apk-auth.env /etc/profile.d/apk-auth.sh"

    # Update package index with auth
    vm_ssh "$ip" "sudo bash -c 'source /etc/profile.d/apk-auth.sh && apk update'"

    log_success "Private APK repository configured on $ip"
}

# Install Kubernetes packages on a node
install_k8s() {
    local ip="$1"
    local k8s_minor=$(echo "$K8S_VERSION" | cut -d. -f1,2)

    log_info "Installing Kubernetes packages on $ip..."

    # Remove Docker packages (keep containerd for Kubernetes)
    vm_ssh "$ip" "sudo pkill dockerd 2>/dev/null || true"
    vm_ssh "$ip" "sudo rm -f /var/run/docker.sock /run/docker.sock 2>/dev/null || true"
    vm_ssh "$ip" "sudo sed -i '/^docker$/d; /^dockerd$/d; /^dockerd-service$/d' /etc/apk/world"
    vm_ssh "$ip" "sudo apk del docker-cli docker-cli-buildx docker-compose dockerd-service-28 dockerd-28 docker-init-28 docker-28 2>/dev/null || true"

    if [[ "$USE_PRIVATE_APK" == "true" ]]; then
        # Setup private APK repo first
        setup_private_apk "$ip" "$APK_TOKEN"

        # Install kubeadm, kubelet, kubectl from private repo
        vm_ssh "$ip" "sudo bash -c 'source /etc/profile.d/apk-auth.sh && apk add \
            kubeadm-${k8s_minor} kubectl-${k8s_minor} kubelet-${k8s_minor} \
            kubeadm-${k8s_minor}-default kubectl-${k8s_minor}-default kubelet-${k8s_minor}-default \
            nfs-utils rpcbind losetup'"
    else
        # Use public repo (older versions)
        vm_ssh "$ip" "sudo apk update && sudo apk add \
            kubeadm-${k8s_minor} kubectl-${k8s_minor} kubelet-${k8s_minor} \
            kubeadm-${k8s_minor}-default kubectl-${k8s_minor}-default kubelet-${k8s_minor}-default \
            nfs-utils rpcbind losetup"
    fi

    # Create rpcbind systemd service (required for NFS, no unit included in package)
    vm_ssh "$ip" 'cat > /tmp/rpcbind.service << '\''EOF'\''
[Unit]
Description=RPC Bind Service
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/rpcbind
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/rpcbind.service /etc/systemd/system/rpcbind.service
sudo systemctl daemon-reload
sudo systemctl enable --now rpcbind'

    # Install CNI plugins (Calico brings its own, but these are useful for debugging)
    vm_ssh "$ip" "sudo apk add cni-plugins-loopback-compat cni-plugins-host-local-compat cni-plugins-portmap-compat"

    # Create required directories
    vm_ssh "$ip" "sudo mkdir -p /var/log/pods /etc/kubernetes/manifests"

    # Create kubelet systemd service
    vm_ssh "$ip" 'cat > /tmp/kubelet.service << '\''EOF'\''
[Unit]
Description=kubelet: The Kubernetes Node Agent
Wants=network-online.target
After=network-online.target

[Service]
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
ExecStart=/usr/bin/kubelet $KUBELET_KUBEADM_ARGS --config=/var/lib/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/kubelet.service /etc/systemd/system/kubelet.service
sudo systemctl daemon-reload
sudo systemctl enable kubelet'

    log_success "Kubernetes packages installed on $ip"
}

# Install packages on all nodes
log_info "Installing Kubernetes packages on all nodes..."
for ip in "${CP_IPS[@]}" "${WORKER_IPS[@]}"; do
    install_k8s "$ip"
done
echo ""

# Configure containerd pause image on all nodes
log_info "Configuring containerd for Chainguard images..."
for ip in "${CP_IPS[@]}" "${WORKER_IPS[@]}"; do
    configure_containerd "$ip"
done
echo ""

# Initialize control plane
CP_IP="${CP_IPS[0]}"
log_info "Initializing control plane on $CP_IP..."

# Get the actual installed kubeadm version
KUBEADM_VERSION=$(vm_ssh "$CP_IP" "kubeadm version -o short" | tr -d 'v')
log_info "Using kubeadm version: $KUBEADM_VERSION"

# The config carries what used to be init flags (--pod-network-cidr,
# --service-cidr, --apiserver-advertise-address, --kubernetes-version); kubeadm
# rejects mixing --config with those.
write_kubeadm_config "$CP_IP"
resolve_k8s_images "$CP_IP"
echo ""

# Prepare Kubernetes images on control plane
prepare_k8s_images "$CP_IP"
echo ""

vm_ssh "$CP_IP" "sudo kubeadm init --config $KUBEADM_CONFIG_PATH" || die "kubeadm init failed"

# Set up kubectl for the user
vm_ssh "$CP_IP" "mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown \$(id -u):\$(id -g) ~/.kube/config"

log_success "Control plane initialized"
echo ""

# Install CNI (Calico)
log_info "Installing Calico CNI..."

# Install Tigera operator (CALICO_VERSION is set by load_versions())
vm_ssh "$CP_IP" "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# Patch Tigera operator to use Chainguard image
log_info "Patching Tigera operator to use Chainguard image..."
vm_ssh "$CP_IP" "kubectl set image deployment/tigera-operator -n tigera-operator \
    tigera-operator=${CG_REGISTRY}/tigera-operator:${TIGERA_OPERATOR_VERSION}"

# Wait for operator to be ready
vm_ssh "$CP_IP" "kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=120s"

# Wait for Installation CRD to be available (operator creates CRDs at runtime)
log_info "Waiting for Tigera CRDs..."
for i in {1..30}; do
    if vm_ssh "$CP_IP" "kubectl get crd installations.operator.tigera.io &>/dev/null"; then
        break
    fi
    sleep 2
done
vm_ssh "$CP_IP" "kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s"

# Create Installation with custom registry (uses Chainguard image naming)
# CG_REGISTRY format: "harbor.cloudnative.biz/cgr/cloudnative.biz"
# Split into registry host and path for Calico operator
CG_REGISTRY_HOST="${CG_REGISTRY%%/*}"
CG_REGISTRY_PATH="${CG_REGISTRY#*/}"
log_info "Creating Calico Installation..."
log_info "  Registry: ${CG_REGISTRY_HOST}"
log_info "  Image path: ${CG_REGISTRY_PATH}"
vm_ssh "$CP_IP" "cat <<EOF | kubectl create -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  variant: Calico
  registry: ${CG_REGISTRY_HOST}
  imagePath: ${CG_REGISTRY_PATH}
  imagePrefix: calico-
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF"
log_success "Calico installed"
echo ""

# Get join command
log_info "Getting worker join command..."
JOIN_CMD=$(vm_ssh "$CP_IP" "sudo kubeadm token create --print-join-command")

# Prepare images on workers (kube-proxy is needed)
log_info "Preparing Kubernetes images on workers..."
for ip in "${WORKER_IPS[@]}"; do
    prepare_k8s_images "$ip"
done
echo ""

# Join workers
for ((i = 0; i < WORKER_COUNT; i++)); do
    ip="${WORKER_IPS[$i]}"
    log_info "Joining worker-$i ($ip)..."
    vm_ssh "$ip" "sudo $JOIN_CMD" || die "Failed to join worker-$i"
    log_success "Worker-$i joined"
done
echo ""

# Fetch kubeconfig
log_info "Fetching kubeconfig..."
scp -o StrictHostKeyChecking=accept-new -i "$CI_SSH_KEY" \
    "${CI_USER}@${CP_IP}:~/.kube/config" "$PROJECT_DIR/kubeconfig"

# Update server address to use control plane IP
sed "s|server:.*|server: https://${CP_IP}:6443|" "$PROJECT_DIR/kubeconfig" > "$PROJECT_DIR/kubeconfig.tmp"
mv "$PROJECT_DIR/kubeconfig.tmp" "$PROJECT_DIR/kubeconfig"

log_success "Kubeconfig saved to $PROJECT_DIR/kubeconfig"
echo ""

# Wait for nodes to be ready
log_info "Waiting for nodes to be ready..."
sleep 10
KUBECONFIG="$PROJECT_DIR/kubeconfig" kubectl get nodes
echo ""

# Install MetalLB
log_info "Installing MetalLB (BGP backend: ${METALLB_BGP_BACKEND})..."
KUBECONFIG="$PROJECT_DIR/kubeconfig" helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
KUBECONFIG="$PROJECT_DIR/kubeconfig" helm repo update

METALLB_ARGS=(
    --set controller.image.repository=${CG_REGISTRY}/metallb-controller
    --set controller.image.tag=${METALLB_VERSION}
    --set speaker.image.repository=${CG_REGISTRY}/metallb-speaker
    --set speaker.image.tag=${METALLB_VERSION}
)

# The chart ships frrk8s.enabled=true, which drops a five-container frr-k8s
# DaemonSet from quay.io onto every node. There is no Chainguard frr-k8s image,
# and L2Advertisement (the default in metallb-config.yaml) needs no BGP backend
# at all, so leave it off unless BGP is actually configured.
case "$METALLB_BGP_BACKEND" in
    none)
        METALLB_ARGS+=(
            --set frrk8s.enabled=false
            --set speaker.frr.enabled=false
        )
        ;;
    frr-k8s)
        log_warn "BGP backend frr-k8s has no Chainguard image: the frr-k8s"
        log_warn "controller will come from quay.io. Only its FRR containers"
        log_warn "can be pointed at Chainguard."
        METALLB_ARGS+=(
            --set frrk8s.enabled=true
            --set speaker.frr.enabled=false
            --set frr-k8s.frrk8s.frr.image.repository=${CG_REGISTRY}/frr
            --set frr-k8s.frrk8s.frr.image.tag=${METALLB_FRR_VERSION}
        )
        ;;
    *)
        die "Unknown metallb.bgp_backend: '$METALLB_BGP_BACKEND' (expected 'none' or 'frr-k8s')"
        ;;
esac

KUBECONFIG="$PROJECT_DIR/kubeconfig" helm upgrade --install --wait \
    --namespace metallb-system --create-namespace \
    --version ${METALLB_CHART_VERSION} \
    "${METALLB_ARGS[@]}" \
    metallb metallb/metallb
log_success "MetalLB installed"

# Wait for MetalLB to be ready before applying config
log_info "Waiting for MetalLB to be ready..."
sleep 5

log_info "Applying MetalLB configuration..."
KUBECONFIG="$PROJECT_DIR/kubeconfig" kubectl apply -f "$PROJECT_DIR/config/metallb-config.yaml" --namespace metallb-system
log_success "MetalLB configured"
echo ""

# Install NFS provisioner
NFS_SERVER=$(yaml_get "$CLUSTER_CONFIG" ".storage.nfs.server" "")
NFS_PATH=$(yaml_get "$CLUSTER_CONFIG" ".storage.nfs.path" "")

if [[ -n "$NFS_SERVER" && -n "$NFS_PATH" ]]; then
    log_info "Installing NFS provisioner..."
    KUBECONFIG="$PROJECT_DIR/kubeconfig" helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
    KUBECONFIG="$PROJECT_DIR/kubeconfig" helm repo update nfs-subdir-external-provisioner
    KUBECONFIG="$PROJECT_DIR/kubeconfig" helm install nfs-provisioner \
        nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
        -n kube-system \
        --set nfs.server="$NFS_SERVER" \
        --set nfs.path="$NFS_PATH" \
        --set 'nfs.mountOptions={nolock}' \
        --set image.repository=${CG_REGISTRY}/nfs-subdir-external-provisioner \
        --set image.tag=${NFS_PROVISIONER_VERSION} \
        --set podSecurityContext.runAsUser=0 \
        --set podSecurityContext.runAsGroup=0

    # Set as default storage class
    KUBECONFIG="$PROJECT_DIR/kubeconfig" kubectl patch storageclass nfs-client \
        -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    log_success "NFS provisioner installed and set as default storage class"
    echo ""
else
    log_info "Skipping NFS provisioner (storage.nfs.server/path not configured)"
    echo ""
fi

# Install metrics-server
log_info "Installing metrics-server..."
KUBECONFIG="$PROJECT_DIR/kubeconfig" helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
KUBECONFIG="$PROJECT_DIR/kubeconfig" helm repo update metrics-server
KUBECONFIG="$PROJECT_DIR/kubeconfig" helm install metrics-server \
    metrics-server/metrics-server \
    -n kube-system \
    --version ${METRICS_SERVER_CHART_VERSION} \
    --set image.repository=${CG_REGISTRY}/metrics-server \
    --set image.tag=${METRICS_SERVER_VERSION} \
    --set args='{--kubelet-insecure-tls}'
log_success "metrics-server installed"
echo ""

log_success "Kubernetes cluster bootstrapped successfully!"
log_info "Use: export KUBECONFIG=$PROJECT_DIR/kubeconfig"
