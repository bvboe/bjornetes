#!/usr/bin/env bash
#
# check-versions.sh - Check for newer versions of cluster components
#
# Usage:
#   ./check-versions.sh [options]
#
# Options:
#   -u, --update       Update versions.yaml with latest versions
#   -h, --help         Show this help message
#
# Components checked:
#   - Kubernetes (GitHub: kubernetes/kubernetes)
#   - etcd + CoreDNS (kubeadm's pin, or the newest Chainguard tag when overridden)
#   - Calico (GitHub: projectcalico/calico)
#   - Tigera Operator (GitHub: tigera/operator)
#   - MetalLB binary + Helm chart (GitHub: metallb/metallb)
#   - NFS Provisioner (GitHub: kubernetes-sigs/nfs-subdir-external-provisioner)
#   - metrics-server binary + Helm chart (GitHub: kubernetes-sigs/metrics-server)
#   - CNI Plugins (GitHub: containernetworking/plugins)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/common.sh"

VERSIONS_FILE="$PROJECT_DIR/config/versions.yaml"
UPDATE=false

usage() {
    head -20 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--update)
            UPDATE=true
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

[[ -f "$VERSIONS_FILE" ]] || die "Versions file not found: $VERSIONS_FILE"

# Check if crane is available for image validation
CAN_CHECK_IMAGES=false
if command -v crane &>/dev/null; then
    CAN_CHECK_IMAGES=true
fi

# Get configured registry
IMAGE_REGISTRY=$(yaml_get "$VERSIONS_FILE" ".images.registry" "cgr.dev/chainguard")

# Check if a container image exists in the registry
# Returns 0 if image exists, 1 if not (or if crane unavailable)
image_exists() {
    local image="$1"
    if $CAN_CHECK_IMAGES; then
        crane manifest "$image" &>/dev/null
    else
        return 0  # Skip check if crane unavailable
    fi
}

# Get latest GitHub release tag.
# Optional second arg is an ERE matched against tag names; when set, /releases
# is scanned and the newest matching tag wins (used to skip metallb's
# interleaved "metallb-chart-*" tags).
github_latest_release() {
    local repo="$1"
    local pattern="${2:-}"
    if [[ -z "$pattern" ]]; then
        curl -s "https://api.github.com/repos/${repo}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
    else
        curl -s "https://api.github.com/repos/${repo}/releases?per_page=30" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' | grep -E "$pattern" | head -1
    fi
}

# Newest tag in the registry matching an ERE, by version order.
# etcd and CoreDNS are tracked against what Chainguard actually publishes rather
# than against their upstream GitHub releases, since an upstream release with no
# Chainguard image is of no use here.
latest_registry_tag() {
    local repo="$1"
    local pattern="$2"
    if ! $CAN_CHECK_IMAGES; then
        echo ""
        return 0
    fi
    crane ls "${IMAGE_REGISTRY}/${repo}" 2>/dev/null | grep -E "$pattern" | sort -V | tail -1
}

# Read one of kubeadm's version constants from a Kubernetes release branch.
# kubeadm pins etcd and CoreDNS per Kubernetes release (1.36 pins etcd 3.6.8-0
# even though 3.6.14 exists). versions.yaml may follow that pin or override it;
# either way the pin is reported, so a divergence stays visible.
kubeadm_pinned() {
    local minor="$1"
    local const="$2"
    curl -s "https://raw.githubusercontent.com/kubernetes/kubernetes/release-${minor}/cmd/kubeadm/app/constants/constants.go" |
        grep -E "^[[:space:]]+${const} = \"" | sed -E 's/.*= "([^"]+)".*/\1/' | head -1
}

log_info "Checking component versions..."
if $CAN_CHECK_IMAGES; then
    log_info "Image validation enabled (using crane)"
else
    log_warn "Image validation skipped (crane not found)"
fi
echo ""

# Current versions from config
CURRENT_K8S=$(yaml_get "$VERSIONS_FILE" ".kubernetes.version" "")
CURRENT_ETCD=$(yaml_get "$VERSIONS_FILE" ".etcd.version" "")
CURRENT_COREDNS=$(yaml_get "$VERSIONS_FILE" ".coredns.version" "")
CURRENT_CALICO=$(yaml_get "$VERSIONS_FILE" ".calico.version" "")
CURRENT_TIGERA=$(yaml_get "$VERSIONS_FILE" ".calico.tigera_operator" "")
CURRENT_METALLB=$(yaml_get "$VERSIONS_FILE" ".metallb.version" "")
CURRENT_METALLB_CHART=$(yaml_get "$VERSIONS_FILE" ".metallb.chart_version" "")
CURRENT_METALLB_BACKEND=$(yaml_get "$VERSIONS_FILE" ".metallb.bgp_backend" "none")
CURRENT_FRR=$(yaml_get "$VERSIONS_FILE" ".metallb.frr_version" "")
CURRENT_NFS=$(yaml_get "$VERSIONS_FILE" ".nfs_provisioner.version" "")
CURRENT_METRICS=$(yaml_get "$VERSIONS_FILE" ".metrics_server.version" "")
CURRENT_METRICS_CHART=$(yaml_get "$VERSIONS_FILE" ".metrics_server.chart_version" "")
CURRENT_CNI=$(yaml_get "$VERSIONS_FILE" ".cni_plugins.version" "")

# kubeadm's pins for the configured minor. Chainguard publishes etcd as vX.Y.Z
# while kubeadm asks for X.Y.Z-N, so drop the kubeadm revision suffix and add the v.
REQUIRED_ETCD_KUBEADM=$(kubeadm_pinned "$CURRENT_K8S" "DefaultEtcdVersion")
REQUIRED_COREDNS_KUBEADM=$(kubeadm_pinned "$CURRENT_K8S" "CoreDNSVersion")
REQUIRED_ETCD=""
REQUIRED_COREDNS=""
if [[ -n "$REQUIRED_ETCD_KUBEADM" ]]; then
    REQUIRED_ETCD="v${REQUIRED_ETCD_KUBEADM%-*}"
fi
if [[ -n "$REQUIRED_COREDNS_KUBEADM" ]]; then
    REQUIRED_COREDNS="$REQUIRED_COREDNS_KUBEADM"
fi

# The tag a bootstrap would actually deploy: either the override or kubeadm's pin
ETCD_EFFECTIVE="$CURRENT_ETCD"
COREDNS_EFFECTIVE="$CURRENT_COREDNS"
if [[ "$CURRENT_ETCD" == "kubeadm" ]]; then
    ETCD_EFFECTIVE="$REQUIRED_ETCD"
fi
if [[ "$CURRENT_COREDNS" == "kubeadm" ]]; then
    COREDNS_EFFECTIVE="$REQUIRED_COREDNS"
fi

# Validate current versions have images available
if $CAN_CHECK_IMAGES; then
    HAS_MISSING=false
    MISSING_IMAGES=()

    # Check Kubernetes
    if ! image_exists "${IMAGE_REGISTRY}/kubernetes-kube-apiserver:${CURRENT_K8S}"; then
        MISSING_IMAGES+=("Kubernetes ${CURRENT_K8S} (kubernetes-kube-apiserver:${CURRENT_K8S})")
        HAS_MISSING=true
    fi

    # Check etcd and CoreDNS at the tag a bootstrap would deploy. When following
    # kubeadm's pin, a missing image here is what makes a cluster come up with the
    # Debian-based upstream control plane images.
    if [[ -n "$ETCD_EFFECTIVE" ]] && ! image_exists "${IMAGE_REGISTRY}/etcd:${ETCD_EFFECTIVE}"; then
        MISSING_IMAGES+=("etcd ${ETCD_EFFECTIVE} (etcd:${ETCD_EFFECTIVE})")
        HAS_MISSING=true
    fi

    if [[ -n "$COREDNS_EFFECTIVE" ]] && ! image_exists "${IMAGE_REGISTRY}/coredns:${COREDNS_EFFECTIVE}"; then
        MISSING_IMAGES+=("CoreDNS ${COREDNS_EFFECTIVE} (coredns:${COREDNS_EFFECTIVE})")
        HAS_MISSING=true
    fi

    # Check Calico
    CALICO_TAG="${CURRENT_CALICO#v}"
    if ! image_exists "${IMAGE_REGISTRY}/calico-node:${CALICO_TAG}"; then
        MISSING_IMAGES+=("Calico ${CURRENT_CALICO} (calico-node:${CALICO_TAG})")
        HAS_MISSING=true
    fi

    # Check Tigera Operator
    TIGERA_TAG="${CURRENT_TIGERA#v}"
    if ! image_exists "${IMAGE_REGISTRY}/tigera-operator:${TIGERA_TAG}"; then
        MISSING_IMAGES+=("Tigera Operator ${CURRENT_TIGERA} (tigera-operator:${TIGERA_TAG})")
        HAS_MISSING=true
    fi

    # Check MetalLB
    if ! image_exists "${IMAGE_REGISTRY}/metallb-controller:${CURRENT_METALLB}"; then
        MISSING_IMAGES+=("MetalLB ${CURRENT_METALLB} (metallb-controller:${CURRENT_METALLB})")
        HAS_MISSING=true
    fi

    # Check MetalLB's FRR image, but only when a BGP backend is actually enabled
    if [[ "$CURRENT_METALLB_BACKEND" != "none" ]] && ! image_exists "${IMAGE_REGISTRY}/frr:${CURRENT_FRR}"; then
        MISSING_IMAGES+=("FRR ${CURRENT_FRR} (frr:${CURRENT_FRR})")
        HAS_MISSING=true
    fi

    # Check NFS Provisioner
    if ! image_exists "${IMAGE_REGISTRY}/nfs-subdir-external-provisioner:${CURRENT_NFS}"; then
        MISSING_IMAGES+=("NFS Provisioner ${CURRENT_NFS} (nfs-subdir-external-provisioner:${CURRENT_NFS})")
        HAS_MISSING=true
    fi

    # Check metrics-server
    if ! image_exists "${IMAGE_REGISTRY}/metrics-server:${CURRENT_METRICS}"; then
        MISSING_IMAGES+=("metrics-server ${CURRENT_METRICS} (metrics-server:${CURRENT_METRICS})")
        HAS_MISSING=true
    fi

    if $HAS_MISSING; then
        echo ""
        log_warn "Configured versions missing from registry:"
        for img in "${MISSING_IMAGES[@]}"; do
            printf "  - %s\n" "$img"
        done
    fi
fi

# Fetch latest versions
log_info "Fetching latest versions from GitHub..."

LATEST_K8S=$(github_latest_release "kubernetes/kubernetes")
LATEST_CALICO=$(github_latest_release "projectcalico/calico")
LATEST_TIGERA=$(github_latest_release "tigera/operator")
LATEST_METALLB=$(github_latest_release "metallb/metallb" '^v[0-9]')
LATEST_METALLB_CHART=$(github_latest_release "metallb/metallb" '^metallb-chart-[0-9]')
LATEST_NFS=$(github_latest_release "kubernetes-sigs/nfs-subdir-external-provisioner")
LATEST_METRICS=$(github_latest_release "kubernetes-sigs/metrics-server" '^v[0-9]')
LATEST_METRICS_CHART=$(github_latest_release "kubernetes-sigs/metrics-server" '^metrics-server-helm-chart-[0-9]')
LATEST_CNI=$(github_latest_release "containernetworking/plugins")

# For an overridden etcd, stay inside the configured minor line (v3.6.x): crossing
# a minor is a much bigger step than tracking patches, and shouldn't happen by
# way of a version check. CoreDNS has no such constraint.
LATEST_ETCD=""
LATEST_COREDNS=""
if [[ "$CURRENT_ETCD" != "kubeadm" && -n "$CURRENT_ETCD" ]]; then
    ETCD_LINE=$(echo "$CURRENT_ETCD" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')
    LATEST_ETCD=$(latest_registry_tag "etcd" "^v${ETCD_LINE//./\\.}\.[0-9]+$")
fi
if [[ "$CURRENT_COREDNS" != "kubeadm" && -n "$CURRENT_COREDNS" ]]; then
    LATEST_COREDNS=$(latest_registry_tag "coredns" '^v[0-9]+\.[0-9]+\.[0-9]+$')
fi

# Kubernetes uses vX.Y.Z format, Chainguard uses X.Y
LATEST_K8S_MINOR=$(echo "$LATEST_K8S" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')
# MetalLB uses vX.Y.Z format, we store as X.Y
LATEST_METALLB_MINOR=$(echo "$LATEST_METALLB" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')
# MetalLB chart tags are metallb-chart-X.Y.Z; strip the prefix
LATEST_METALLB_CHART_CLEAN="${LATEST_METALLB_CHART#metallb-chart-}"
# NFS uses nfs-subdir-external-provisioner-X.Y.Z format, extract version
LATEST_NFS_CLEAN=$(echo "$LATEST_NFS" | sed -E 's/^nfs-subdir-external-provisioner-//')
# metrics-server chart tags are metrics-server-helm-chart-X.Y.Z
LATEST_METRICS_CHART_CLEAN="${LATEST_METRICS_CHART#metrics-server-helm-chart-}"
LATEST_CNI_CLEAN="${LATEST_CNI#v}"

echo ""
log_info "Version comparison:"

HAS_UPDATES=false

# Check Kubernetes (validate image exists)
if [[ "$CURRENT_K8S" == "$LATEST_K8S_MINOR" ]]; then
    printf "  %-20s %-12s %s\n" "Kubernetes:" "$CURRENT_K8S" "(up to date)"
else
    if image_exists "${IMAGE_REGISTRY}/kubernetes-kube-apiserver:${LATEST_K8S_MINOR}"; then
        printf "  %-20s %-12s -> %-12s %s\n" "Kubernetes:" "$CURRENT_K8S" "$LATEST_K8S_MINOR" "(update available)"
        UPDATE_K8S="$LATEST_K8S_MINOR"
        HAS_UPDATES=true
    else
        printf "  %-20s %-12s -> %-12s %s\n" "Kubernetes:" "$CURRENT_K8S" "$LATEST_K8S_MINOR" "(image not available)"
    fi
fi

# etcd: either follow kubeadm's pin, or track the newest Chainguard tag in the
# configured minor line. The kubeadm pin is always printed, so an override never
# quietly becomes invisible.
if [[ "$CURRENT_ETCD" == "kubeadm" ]]; then
    if [[ -n "$REQUIRED_ETCD" ]]; then
        printf "  %-20s %-12s %s\n" "etcd:" "$REQUIRED_ETCD" "(kubeadm pin ${REQUIRED_ETCD_KUBEADM})"
    else
        printf "  %-20s %-12s %s\n" "etcd:" "kubeadm" "(could not read kubeadm pin for $CURRENT_K8S)"
    fi
elif [[ -z "$LATEST_ETCD" || "$CURRENT_ETCD" == "$LATEST_ETCD" ]]; then
    printf "  %-20s %-12s %s\n" "etcd:" "$CURRENT_ETCD" "(latest v${ETCD_LINE:-?}.x; kubeadm pins ${REQUIRED_ETCD_KUBEADM:-unknown})"
else
    printf "  %-20s %-12s -> %-12s %s\n" "etcd:" "$CURRENT_ETCD" "$LATEST_ETCD" "(kubeadm pins ${REQUIRED_ETCD_KUBEADM:-unknown})"
    UPDATE_ETCD="$LATEST_ETCD"
    HAS_UPDATES=true
fi

# CoreDNS: same, tracking the newest Chainguard tag
if [[ "$CURRENT_COREDNS" == "kubeadm" ]]; then
    if [[ -n "$REQUIRED_COREDNS" ]]; then
        printf "  %-20s %-12s %s\n" "CoreDNS:" "$REQUIRED_COREDNS" "(kubeadm pin)"
    else
        printf "  %-20s %-12s %s\n" "CoreDNS:" "kubeadm" "(could not read kubeadm pin for $CURRENT_K8S)"
    fi
elif [[ -z "$LATEST_COREDNS" || "$CURRENT_COREDNS" == "$LATEST_COREDNS" ]]; then
    printf "  %-20s %-12s %s\n" "CoreDNS:" "$CURRENT_COREDNS" "(latest; kubeadm pins ${REQUIRED_COREDNS_KUBEADM:-unknown})"
else
    printf "  %-20s %-12s -> %-12s %s\n" "CoreDNS:" "$CURRENT_COREDNS" "$LATEST_COREDNS" "(kubeadm pins ${REQUIRED_COREDNS_KUBEADM:-unknown})"
    UPDATE_COREDNS="$LATEST_COREDNS"
    HAS_UPDATES=true
fi

# Check Calico (validate image exists)
if [[ "$CURRENT_CALICO" == "$LATEST_CALICO" ]]; then
    printf "  %-20s %-12s %s\n" "Calico:" "$CURRENT_CALICO" "(up to date)"
else
    # Chainguard tags omit 'v' prefix
    CALICO_TAG="${LATEST_CALICO#v}"
    if image_exists "${IMAGE_REGISTRY}/calico-node:${CALICO_TAG}"; then
        printf "  %-20s %-12s -> %-12s %s\n" "Calico:" "$CURRENT_CALICO" "$LATEST_CALICO" "(update available)"
        UPDATE_CALICO="$LATEST_CALICO"
        HAS_UPDATES=true
    else
        printf "  %-20s %-12s -> %-12s %s\n" "Calico:" "$CURRENT_CALICO" "$LATEST_CALICO" "(image not available)"
    fi
fi

# Check Tigera Operator (validate image exists)
if [[ "$CURRENT_TIGERA" == "$LATEST_TIGERA" ]]; then
    printf "  %-20s %-12s %s\n" "Tigera Operator:" "$CURRENT_TIGERA" "(up to date)"
else
    # Chainguard tags may omit 'v' prefix
    TIGERA_TAG="${LATEST_TIGERA#v}"
    if image_exists "${IMAGE_REGISTRY}/tigera-operator:${TIGERA_TAG}"; then
        printf "  %-20s %-12s -> %-12s %s\n" "Tigera Operator:" "$CURRENT_TIGERA" "$LATEST_TIGERA" "(update available)"
        UPDATE_TIGERA="$LATEST_TIGERA"
        HAS_UPDATES=true
    else
        printf "  %-20s %-12s -> %-12s %s\n" "Tigera Operator:" "$CURRENT_TIGERA" "$LATEST_TIGERA" "(image not available)"
    fi
fi

# Check MetalLB (validate image exists)
if [[ "$CURRENT_METALLB" == "$LATEST_METALLB_MINOR" ]]; then
    printf "  %-20s %-12s %s\n" "MetalLB:" "$CURRENT_METALLB" "(up to date)"
else
    if image_exists "${IMAGE_REGISTRY}/metallb-controller:${LATEST_METALLB_MINOR}"; then
        printf "  %-20s %-12s -> %-12s %s\n" "MetalLB:" "$CURRENT_METALLB" "$LATEST_METALLB_MINOR" "(update available)"
        UPDATE_METALLB="$LATEST_METALLB_MINOR"
        HAS_UPDATES=true
    else
        printf "  %-20s %-12s -> %-12s %s\n" "MetalLB:" "$CURRENT_METALLB" "$LATEST_METALLB_MINOR" "(image not available)"
    fi
fi

# Check MetalLB Helm chart — chart and image drift independently in this repo
if [[ "$CURRENT_METALLB_CHART" == "$LATEST_METALLB_CHART_CLEAN" ]]; then
    printf "  %-20s %-12s %s\n" "MetalLB chart:" "$CURRENT_METALLB_CHART" "(up to date)"
else
    printf "  %-20s %-12s -> %-12s %s\n" "MetalLB chart:" "$CURRENT_METALLB_CHART" "$LATEST_METALLB_CHART_CLEAN" "(update available)"
    UPDATE_METALLB_CHART="$LATEST_METALLB_CHART_CLEAN"
    HAS_UPDATES=true
fi

# Check NFS Provisioner (validate image exists)
if [[ "$CURRENT_NFS" == "$LATEST_NFS_CLEAN" ]]; then
    printf "  %-20s %-12s %s\n" "NFS Provisioner:" "$CURRENT_NFS" "(up to date)"
else
    if image_exists "${IMAGE_REGISTRY}/nfs-subdir-external-provisioner:${LATEST_NFS_CLEAN}"; then
        printf "  %-20s %-12s -> %-12s %s\n" "NFS Provisioner:" "$CURRENT_NFS" "$LATEST_NFS_CLEAN" "(update available)"
        UPDATE_NFS="$LATEST_NFS_CLEAN"
        HAS_UPDATES=true
    else
        printf "  %-20s %-12s -> %-12s %s\n" "NFS Provisioner:" "$CURRENT_NFS" "$LATEST_NFS_CLEAN" "(image not available)"
    fi
fi

# Check metrics-server (validate image exists)
if [[ "$CURRENT_METRICS" == "$LATEST_METRICS" ]]; then
    printf "  %-20s %-12s %s\n" "metrics-server:" "$CURRENT_METRICS" "(up to date)"
else
    if image_exists "${IMAGE_REGISTRY}/metrics-server:${LATEST_METRICS}"; then
        printf "  %-20s %-12s -> %-12s %s\n" "metrics-server:" "$CURRENT_METRICS" "$LATEST_METRICS" "(update available)"
        UPDATE_METRICS="$LATEST_METRICS"
        HAS_UPDATES=true
    else
        printf "  %-20s %-12s -> %-12s %s\n" "metrics-server:" "$CURRENT_METRICS" "$LATEST_METRICS" "(image not available)"
    fi
fi

# Check metrics-server Helm chart
if [[ "$CURRENT_METRICS_CHART" == "$LATEST_METRICS_CHART_CLEAN" ]]; then
    printf "  %-20s %-12s %s\n" "metrics-server chart:" "$CURRENT_METRICS_CHART" "(up to date)"
else
    printf "  %-20s %-12s -> %-12s %s\n" "metrics-server chart:" "$CURRENT_METRICS_CHART" "$LATEST_METRICS_CHART_CLEAN" "(update available)"
    UPDATE_METRICS_CHART="$LATEST_METRICS_CHART_CLEAN"
    HAS_UPDATES=true
fi

# Check CNI Plugins (no image check - installed as APK packages)
if [[ "$CURRENT_CNI" == "$LATEST_CNI_CLEAN" ]]; then
    printf "  %-20s %-12s %s\n" "CNI Plugins:" "$CURRENT_CNI" "(up to date)"
else
    printf "  %-20s %-12s -> %-12s %s\n" "CNI Plugins:" "$CURRENT_CNI" "$LATEST_CNI_CLEAN" "(update available)"
    UPDATE_CNI="$LATEST_CNI_CLEAN"
    HAS_UPDATES=true
fi

echo ""

# Apply updates if requested
if $UPDATE && $HAS_UPDATES; then
    log_info "Updating versions.yaml..."

    if [[ -n "${UPDATE_K8S:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^kubernetes:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_K8S}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^kubernetes:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_K8S}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated Kubernetes to $UPDATE_K8S"
    fi

    if [[ -n "${UPDATE_ETCD:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^etcd:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_ETCD}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^etcd:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_ETCD}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated etcd to $UPDATE_ETCD"
    fi

    if [[ -n "${UPDATE_COREDNS:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^coredns:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_COREDNS}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^coredns:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_COREDNS}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated CoreDNS to $UPDATE_COREDNS"
    fi

    if [[ -n "${UPDATE_CALICO:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^calico:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_CALICO}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^calico:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_CALICO}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated Calico to $UPDATE_CALICO"
    fi

    if [[ -n "${UPDATE_TIGERA:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s/^\(  tigera_operator: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_TIGERA}\2/" "$VERSIONS_FILE"
        else
            sed -i "s/^\(  tigera_operator: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_TIGERA}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated Tigera Operator to $UPDATE_TIGERA"
    fi

    if [[ -n "${UPDATE_METALLB:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^metallb:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_METALLB}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^metallb:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_METALLB}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated MetalLB to $UPDATE_METALLB"
    fi

    # Scoped to the metallb block: metrics_server has a chart_version too
    if [[ -n "${UPDATE_METALLB_CHART:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^metallb:/,/^[a-z]/ s/^\(  chart_version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_METALLB_CHART}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^metallb:/,/^[a-z]/ s/^\(  chart_version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_METALLB_CHART}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated MetalLB chart to $UPDATE_METALLB_CHART"
    fi

    if [[ -n "${UPDATE_NFS:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^nfs_provisioner:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_NFS}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^nfs_provisioner:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_NFS}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated NFS Provisioner to $UPDATE_NFS"
    fi

    if [[ -n "${UPDATE_METRICS:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^metrics_server:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_METRICS}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^metrics_server:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_METRICS}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated metrics-server to $UPDATE_METRICS"
    fi

    if [[ -n "${UPDATE_METRICS_CHART:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^metrics_server:/,/^[a-z]/ s/^\(  chart_version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_METRICS_CHART}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^metrics_server:/,/^[a-z]/ s/^\(  chart_version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_METRICS_CHART}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated metrics-server chart to $UPDATE_METRICS_CHART"
    fi

    if [[ -n "${UPDATE_CNI:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^cni_plugins:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_CNI}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^cni_plugins:/,/^[a-z]/ s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_CNI}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated CNI Plugins to $UPDATE_CNI"
    fi

    echo ""
    log_success "versions.yaml updated. Review changes before deploying."
elif $UPDATE; then
    log_success "All components are up to date!"
elif $HAS_UPDATES; then
    log_info "Run with --update to apply updates to versions.yaml"
else
    log_success "All components are up to date!"
fi
