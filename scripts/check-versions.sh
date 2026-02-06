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
#   - Calico CNI (GitHub: projectcalico/calico)
#   - Tigera Operator (GitHub: tigera/operator)
#   - MetalLB (GitHub: metallb/metallb)
#   - CNI Plugins (GitHub: containernetworking/plugins)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/common.sh"

VERSIONS_FILE="$PROJECT_DIR/config/versions.yaml"
UPDATE=false

usage() {
    head -18 "$0" | grep "^#" | cut -c 3-
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

# Get latest GitHub release tag
github_latest_release() {
    local repo="$1"
    curl -s "https://api.github.com/repos/${repo}/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

log_info "Checking component versions..."
echo ""

# Current versions from config
CURRENT_CALICO=$(yaml_get "$VERSIONS_FILE" ".calico.version" "")
CURRENT_TIGERA=$(yaml_get "$VERSIONS_FILE" ".calico.tigera_operator" "")
CURRENT_METALLB=$(yaml_get "$VERSIONS_FILE" ".metallb.version" "")
CURRENT_CNI=$(yaml_get "$VERSIONS_FILE" ".cni_plugins.version" "")

# Fetch latest versions
log_info "Fetching latest versions from GitHub..."

LATEST_CALICO=$(github_latest_release "projectcalico/calico")
LATEST_TIGERA=$(github_latest_release "tigera/operator")
LATEST_METALLB=$(github_latest_release "metallb/metallb")
LATEST_CNI=$(github_latest_release "containernetworking/plugins")

# MetalLB uses vX.Y.Z format, we store as X.Y
LATEST_METALLB_MINOR=$(echo "$LATEST_METALLB" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')
LATEST_CNI_CLEAN="${LATEST_CNI#v}"

echo ""
log_info "Version comparison:"

HAS_UPDATES=false

# Check Calico
if [[ "$CURRENT_CALICO" == "$LATEST_CALICO" ]]; then
    printf "  %-20s %-12s %s\n" "Calico:" "$CURRENT_CALICO" "(up to date)"
else
    printf "  %-20s %-12s -> %-12s %s\n" "Calico:" "$CURRENT_CALICO" "$LATEST_CALICO" "(update available)"
    UPDATE_CALICO="$LATEST_CALICO"
    HAS_UPDATES=true
fi

# Check Tigera Operator
if [[ "$CURRENT_TIGERA" == "$LATEST_TIGERA" ]]; then
    printf "  %-20s %-12s %s\n" "Tigera Operator:" "$CURRENT_TIGERA" "(up to date)"
else
    printf "  %-20s %-12s -> %-12s %s\n" "Tigera Operator:" "$CURRENT_TIGERA" "$LATEST_TIGERA" "(update available)"
    UPDATE_TIGERA="$LATEST_TIGERA"
    HAS_UPDATES=true
fi

# Check MetalLB
if [[ "$CURRENT_METALLB" == "$LATEST_METALLB_MINOR" ]]; then
    printf "  %-20s %-12s %s\n" "MetalLB:" "$CURRENT_METALLB" "(up to date)"
else
    printf "  %-20s %-12s -> %-12s %s\n" "MetalLB:" "$CURRENT_METALLB" "$LATEST_METALLB_MINOR" "(update available)"
    UPDATE_METALLB="$LATEST_METALLB_MINOR"
    HAS_UPDATES=true
fi

# Check CNI Plugins
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

    if [[ -n "${UPDATE_CALICO:-}" ]]; then
        # Update calico version
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_CALICO}\2/" "$VERSIONS_FILE"
        else
            sed -i "s/^\(  version: *\"\)v\{0,1\}[0-9.]*\(\"\)/\1${UPDATE_CALICO}\2/" "$VERSIONS_FILE"
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
        # MetalLB is under metallb: section, need to be more specific
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^metallb:/,/^[a-z]/ s/^\(  version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_METALLB}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^metallb:/,/^[a-z]/ s/^\(  version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_METALLB}\2/" "$VERSIONS_FILE"
        fi
        log_success "  Updated MetalLB to $UPDATE_METALLB"
    fi

    if [[ -n "${UPDATE_CNI:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^cni_plugins:/,/^[a-z]/ s/^\(  version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_CNI}\2/" "$VERSIONS_FILE"
        else
            sed -i "/^cni_plugins:/,/^[a-z]/ s/^\(  version: *\"\)[0-9.]*\(\"\)/\1${UPDATE_CNI}\2/" "$VERSIONS_FILE"
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
