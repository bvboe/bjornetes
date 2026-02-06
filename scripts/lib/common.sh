#!/usr/bin/env bash
# Common utilities and functions

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

# Check for required commands
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd"
    fi
}

# YAML parsing using yq (https://github.com/mikefarah/yq)
# Falls back to python if yq is not available
yaml_get() {
    local file="$1"
    local path="$2"
    local default="${3:-}"

    if command -v yq &>/dev/null; then
        local result
        result=$(yq -r "$path // \"__NULL__\"" "$file" 2>/dev/null)
        if [[ "$result" == "__NULL__" || "$result" == "null" ]]; then
            echo "$default"
        else
            echo "$result"
        fi
    elif command -v python3 &>/dev/null; then
        python3 -c "
import yaml
import sys

with open('$file', 'r') as f:
    data = yaml.safe_load(f)

path = '$path'.lstrip('.')
parts = path.replace('[', '.').replace(']', '').split('.')
parts = [p for p in parts if p]

result = data
try:
    for part in parts:
        if part.isdigit():
            result = result[int(part)]
        else:
            result = result[part]
    print(result if result is not None else '$default')
except (KeyError, IndexError, TypeError):
    print('$default')
"
    else
        die "Neither yq nor python3 available for YAML parsing"
    fi
}

# Get all keys at a path
yaml_keys() {
    local file="$1"
    local path="$2"

    if command -v yq &>/dev/null; then
        yq -r "$path | keys | .[]" "$file" 2>/dev/null || true
    elif command -v python3 &>/dev/null; then
        python3 -c "
import yaml

with open('$file', 'r') as f:
    data = yaml.safe_load(f)

path = '$path'.lstrip('.')
parts = path.replace('[', '.').replace(']', '').split('.')
parts = [p for p in parts if p]

result = data
try:
    for part in parts:
        if part.isdigit():
            result = result[int(part)]
        else:
            result = result[part]
    if isinstance(result, dict):
        for key in result.keys():
            print(key)
except (KeyError, IndexError, TypeError):
    pass
"
    else
        die "Neither yq nor python3 available for YAML parsing"
    fi
}

# Expand ~ in paths
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Generate a name from pattern
# e.g., generate_name "cp-{index}" 0 -> "cp-0"
generate_name() {
    local pattern="$1"
    local index="$2"
    echo "${pattern//\{index\}/$index}"
}

# Wait for a condition with timeout
wait_for() {
    local description="$1"
    local timeout="$2"
    local check_cmd="$3"

    local elapsed=0
    local interval=5

    log_info "Waiting for $description (timeout: ${timeout}s)..."

    while ! eval "$check_cmd" &>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for $description"
            return 1
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_success "$description ready"
    return 0
}

# Calculate IP address by adding offset to base IP
# Usage: ip_add_offset "192.168.1.100" 2 -> "192.168.1.102"
ip_add_offset() {
    local base_ip="$1"
    local offset="$2"

    # Split IP into octets
    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$base_ip"

    # Add offset to last octet (simple case, no overflow handling)
    local new_o4=$((o4 + offset))

    echo "${o1}.${o2}.${o3}.${new_o4}"
}

# Create a temporary directory that's cleaned up on exit
TEMP_DIRS=()
cleanup_temp() {
    if [[ ${#TEMP_DIRS[@]} -gt 0 ]]; then
        for dir in "${TEMP_DIRS[@]}"; do
            [[ -d "$dir" ]] && rm -rf "$dir"
        done
    fi
}
trap cleanup_temp EXIT

make_temp_dir() {
    local dir
    dir=$(mktemp -d)
    TEMP_DIRS+=("$dir")
    echo "$dir"
}

# Load versions configuration from config/versions.yaml
# Sets global variables for component versions
# Usage: load_versions [versions_file]
load_versions() {
    local versions_file="${1:-}"
    local script_dir

    # Find the versions file relative to project root
    if [[ -z "$versions_file" ]]; then
        # Try to locate based on common script locations
        if [[ -n "${PROJECT_DIR:-}" ]]; then
            versions_file="$PROJECT_DIR/config/versions.yaml"
        elif [[ -n "${SCRIPT_DIR:-}" ]]; then
            versions_file="$(dirname "$SCRIPT_DIR")/config/versions.yaml"
        else
            script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            versions_file="$(dirname "$(dirname "$script_dir")")/config/versions.yaml"
        fi
    fi

    if [[ ! -f "$versions_file" ]]; then
        log_warn "Versions config not found: $versions_file, using defaults"
        # Set defaults
        CG_REGISTRY="${CG_REGISTRY:-cgr.dev/chainguard}"
        CG_K8S_TAG="${CG_K8S_TAG:-1.35}"
        CALICO_VERSION="${CALICO_VERSION:-v3.31.3}"
        TIGERA_OPERATOR_VERSION="${TIGERA_OPERATOR_VERSION:-v1.40.4}"
        METALLB_VERSION="${METALLB_VERSION:-0.15}"
        METALLB_FRR_VERSION="${METALLB_FRR_VERSION:-10.5}"
        NFS_PROVISIONER_VERSION="${NFS_PROVISIONER_VERSION:-4.0}"
        CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-1.6.2}"
        VM_SSH_USER="${VM_SSH_USER:-linky}"
        return 0
    fi

    # Load versions from config
    CG_REGISTRY=$(yaml_get "$versions_file" ".images.registry" "cgr.dev/chainguard")
    CG_K8S_TAG=$(yaml_get "$versions_file" ".kubernetes.version" "1.35")
    CALICO_VERSION=$(yaml_get "$versions_file" ".calico.version" "v3.31.3")
    TIGERA_OPERATOR_VERSION=$(yaml_get "$versions_file" ".calico.tigera_operator" "v1.40.4")
    METALLB_VERSION=$(yaml_get "$versions_file" ".metallb.version" "0.15")
    METALLB_FRR_VERSION=$(yaml_get "$versions_file" ".metallb.frr_version" "10.5")
    NFS_PROVISIONER_VERSION=$(yaml_get "$versions_file" ".nfs_provisioner.version" "4.0")
    CNI_PLUGINS_VERSION=$(yaml_get "$versions_file" ".cni_plugins.version" "1.6.2")
    VM_SSH_USER=$(yaml_get "$versions_file" ".vm_ssh_user" "linky")

    log_info "Loaded versions from $versions_file"
}
