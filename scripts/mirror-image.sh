#!/usr/bin/env bash
#
# mirror-image.sh - Copy container images between registries with multi-platform support
#
# Usage:
#   ./mirror-image.sh <source-image> <destination-image>
#   ./mirror-image.sh -f <file>  # Read image pairs from file (src dest per line)
#
# Examples:
#   ./mirror-image.sh docker.io/nginx:latest myregistry.com/nginx:latest
#   ./mirror-image.sh gcr.io/project/app:v1 ghcr.io/org/app:v1
#
# Options:
#   -f, --file FILE    Read image pairs from file (one "source dest" per line)
#   -n, --dry-run      Show what would be copied without copying
#   -v, --verbose      Show detailed output
#   -h, --help         Show this help message
#
# Requirements:
#   - crane (go-containerregistry): https://github.com/google/go-containerregistry
#     Install: go install github.com/google/go-containerregistry/cmd/crane@latest
#     Or: brew install crane
#
# Authentication:
#   - Use 'crane auth login <registry>' or
#   - Set up ~/.docker/config.json
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die() { log_error "$*"; exit 1; }

# Options
DRY_RUN=false
VERBOSE=false
IMAGE_FILE=""

usage() {
    head -25 "$0" | grep "^#" | cut -c 3-
    exit 0
}

# Check for crane
check_requirements() {
    if ! command -v crane &>/dev/null; then
        die "crane is required but not found. Install with: brew install crane"
    fi
}

# Get platforms for an image
get_platforms() {
    local image="$1"
    crane manifest "$image" 2>/dev/null | jq -r '
        if .manifests then
            .manifests[] | "\(.platform.os)/\(.platform.architecture)" + (if .platform.variant then "/\(.platform.variant)" else "" end)
        else
            "single-arch"
        end
    ' 2>/dev/null || echo "unknown"
}

# Copy a single image (all platforms)
copy_image() {
    local src="$1"
    local dst="$2"

    log_info "Copying: $src -> $dst"

    # Get source platforms
    if $VERBOSE; then
        local platforms
        platforms=$(get_platforms "$src")
        if [[ "$platforms" != "single-arch" && "$platforms" != "unknown" ]]; then
            log_info "  Platforms: $(echo "$platforms" | tr '\n' ' ')"
        fi
    fi

    if $DRY_RUN; then
        log_warn "  [DRY-RUN] Would copy $src to $dst"
        return 0
    fi

    # crane copy preserves multi-arch manifests
    if crane copy "$src" "$dst" 2>&1; then
        log_success "  Copied successfully"
        return 0
    else
        log_error "  Failed to copy"
        return 1
    fi
}

# Process image file
process_file() {
    local file="$1"
    local failed=0
    local copied=0

    [[ -f "$file" ]] || die "File not found: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse source and destination
        read -r src dst <<< "$line"

        if [[ -z "$src" || -z "$dst" ]]; then
            log_warn "Skipping invalid line: $line"
            continue
        fi

        if copy_image "$src" "$dst"; then
            ((copied++))
        else
            ((failed++))
        fi
    done < "$file"

    echo ""
    log_info "Summary: $copied copied, $failed failed"
    [[ $failed -eq 0 ]] || return 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)
            IMAGE_FILE="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

check_requirements

if [[ -n "$IMAGE_FILE" ]]; then
    process_file "$IMAGE_FILE"
elif [[ $# -eq 2 ]]; then
    copy_image "$1" "$2"
else
    usage
fi
