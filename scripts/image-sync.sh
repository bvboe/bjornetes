#!/usr/bin/env bash
#
# image-sync.sh - Download and import VM images to Proxmox
#
# Usage:
#   ./image-sync.sh [options] [source_name...]
#
# Options:
#   -c, --cluster-config FILE   Path to cluster config (default: config/cluster.yaml)
#   -i, --images-config FILE    Path to images config (default: config/image-sources.yaml)
#   -s, --start-vmid NUM        Starting VMID for templates (default: 9000)
#   -k, --keep NUM              Number of old versions to keep (default: 3)
#   --cleanup                   Run cleanup after sync (delete old versions)
#   --cleanup-only              Only run cleanup, don't sync new images
#   --check                     Check for new versions without downloading
#   -v, --version DATE          Download specific version (e.g., 20260121 or 20260121-0337)
#   --list-versions             List available versions in GCS bucket
#   -l, --list                  List configured image sources and existing templates
#   -h, --help                  Show this help message
#
# If no source names are provided, syncs all configured sources.
#

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
START_VMID=9000
KEEP_VERSIONS=3

# Parse command line arguments
SOURCES_TO_SYNC=()
LIST_ONLY=false
CHECK_ONLY=false
DO_CLEANUP=false
CLEANUP_ONLY=false
LIST_VERSIONS=false
TARGET_VERSION=""

usage() {
    head -30 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cluster-config)
            CLUSTER_CONFIG="$2"
            shift 2
            ;;
        -i|--images-config)
            IMAGES_CONFIG="$2"
            shift 2
            ;;
        -s|--start-vmid)
            START_VMID="$2"
            shift 2
            ;;
        -k|--keep)
            KEEP_VERSIONS="$2"
            shift 2
            ;;
        --cleanup)
            DO_CLEANUP=true
            shift
            ;;
        --cleanup-only)
            CLEANUP_ONLY=true
            DO_CLEANUP=true
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        -v|--version)
            TARGET_VERSION="$2"
            shift 2
            ;;
        --list-versions)
            LIST_VERSIONS=true
            shift
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            SOURCES_TO_SYNC+=("$1")
            shift
            ;;
    esac
done

# Validate config files exist
if [[ ! -f "$CLUSTER_CONFIG" ]]; then
    die "Cluster config not found: $CLUSTER_CONFIG"
fi

if [[ ! -f "$IMAGES_CONFIG" ]]; then
    die "Images config not found: $IMAGES_CONFIG"
fi

# Check for yq or python3
if ! command -v yq &>/dev/null && ! command -v python3 &>/dev/null; then
    die "Either 'yq' or 'python3' is required for YAML parsing"
fi

# Check if any GCS sources are configured and verify gcloud auth
has_gcs_sources() {
    for src in $(image_list_sources "$IMAGES_CONFIG" 2>/dev/null); do
        if [[ "$(image_get_type "$IMAGES_CONFIG" "$src")" == "gcs" ]]; then
            return 0
        fi
    done
    return 1
}

if has_gcs_sources; then
    if ! command -v gcloud &>/dev/null; then
        die "gcloud CLI is required for GCS image sources but not found. Install with: brew install google-cloud-sdk"
    fi

    # Check if authenticated (gcloud auth list returns non-zero or empty if no active account)
    if ! gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | grep -q .; then
        log_error "gcloud is not authenticated. Run: gcloud auth login"
        die "GCS sources require gcloud authentication"
    fi
fi

# List sources and exit if requested
if [[ "$LIST_ONLY" == "true" ]]; then
    # Initialize Proxmox connection for listing images
    pve_init "$CLUSTER_CONFIG"

    echo "Configured image sources:"
    echo ""
    for source in $(image_list_sources "$IMAGES_CONFIG"); do
        src_type=$(image_get_type "$IMAGES_CONFIG" "$source")
        template=$(image_get_template_name "$IMAGES_CONFIG" "$source")
        import_dir=$(image_get_import_dir "$IMAGES_CONFIG" "$source")
        echo "  $source"
        echo "    Type:       $src_type"
        echo "    Base name:  $template"
        echo "    Import dir: $import_dir"
        if [[ "$src_type" == "gcs" ]]; then
            bucket=$(image_get_bucket_path "$IMAGES_CONFIG" "$source")
            echo "    Bucket:     $bucket"
        fi

        # List existing qcow2 files in import directory
        existing=$(pve_ssh "ls -1 ${import_dir}/${template}-*.qcow2 2>/dev/null | sort -r" || true)
        if [[ -n "$existing" ]]; then
            echo "    Existing images:"
            while read -r filepath; do
                [[ -z "$filepath" ]] && continue
                filename=$(basename "$filepath")
                echo "      - $filename"
            done <<< "$existing"
        fi
        echo ""
    done
    exit 0
fi

# List available versions in GCS
if [[ "$LIST_VERSIONS" == "true" ]]; then
    for source in $(image_list_sources "$IMAGES_CONFIG"); do
        src_type=$(image_get_type "$IMAGES_CONFIG" "$source")

        if [[ "$src_type" != "gcs" ]]; then
            echo "Source '$source' is type '$src_type', --list-versions only works with GCS sources"
            continue
        fi

        bucket_path=$(image_get_bucket_path "$IMAGES_CONFIG" "$source")
        echo "Available versions for '$source' ($bucket_path):"
        echo ""

        image_gcs_list_versions "$bucket_path" | head -20 | while read -r version; do
            echo "  $version"
        done

        echo ""
        echo "(showing up to 20 most recent versions)"
    done
    exit 0
fi

# Initialize Proxmox connection
pve_init "$CLUSTER_CONFIG"

# Test connection
pve_test_connection || die "Cannot connect to Proxmox"

# Get list of sources to process
if [[ ${#SOURCES_TO_SYNC[@]} -eq 0 ]]; then
    while IFS= read -r src; do
        [[ -n "$src" ]] && SOURCES_TO_SYNC+=("$src")
    done < <(image_list_sources "$IMAGES_CONFIG")
fi

if [[ ${#SOURCES_TO_SYNC[@]} -eq 0 ]]; then
    die "No image sources configured"
fi

# Check-only mode: just show what's available
if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Checking for updates..."
    echo ""

    for source in "${SOURCES_TO_SYNC[@]}"; do
        src_type=$(image_get_type "$IMAGES_CONFIG" "$source")
        template=$(image_get_template_name "$IMAGES_CONFIG" "$source")

        echo "Source: $source"

        if [[ "$src_type" == "gcs" ]]; then
            bucket_path=$(image_get_bucket_path "$IMAGES_CONFIG" "$source")
            import_dir=$(image_get_import_dir "$IMAGES_CONFIG" "$source")
            image_gcs_get_latest_version "$bucket_path" || continue

            versioned_filename="${template}-${GCS_LATEST_VERSION}.qcow2"
            import_path="${import_dir}/${versioned_filename}"

            if pve_ssh "test -f '$import_path'" 2>/dev/null; then
                echo "  Latest:   $GCS_LATEST_VERSION (already exists in $import_dir)"
                echo "  Action:   Skip (up to date)"
            else
                echo "  Latest:   $GCS_LATEST_VERSION (new)"
                echo "  Action:   Would download to $import_dir"
            fi
        else
            echo "  Type:     $src_type (check not supported)"
        fi
        echo ""
    done
    exit 0
fi

# Cleanup-only mode
if [[ "$CLEANUP_ONLY" == "true" ]]; then
    log_info "Running cleanup only (keeping $KEEP_VERSIONS versions)..."
    echo ""

    for source in "${SOURCES_TO_SYNC[@]}"; do
        template=$(image_get_template_name "$IMAGES_CONFIG" "$source")
        import_dir=$(image_get_import_dir "$IMAGES_CONFIG" "$source")
        echo "----------------------------------------"
        image_cleanup_old_versions "$template" "$import_dir" "$KEEP_VERSIONS" false
        echo ""
    done

    log_success "Cleanup complete"
    exit 0
fi

# Normal sync mode
log_info "Starting image sync..."
log_info "  Sources: ${SOURCES_TO_SYNC[*]}"
log_info "  Starting VMID: $START_VMID"
if [[ -n "$TARGET_VERSION" ]]; then
    log_info "  Target version: $TARGET_VERSION"
fi
if [[ "$DO_CLEANUP" == "true" ]]; then
    log_info "  Cleanup: enabled (keeping $KEEP_VERSIONS versions)"
fi
echo ""

# Sync each source
vmid=$START_VMID
failed=()

for source in "${SOURCES_TO_SYNC[@]}"; do
    echo "----------------------------------------"

    if image_sync_source "$IMAGES_CONFIG" "$CLUSTER_CONFIG" "$source" "$vmid" "$TARGET_VERSION"; then
        log_success "Source '$source' synced successfully"
    else
        log_error "Failed to sync source '$source'"
        failed+=("$source")
    fi

    vmid=$((vmid + 1))
    echo ""
done

# Run cleanup if requested
if [[ "$DO_CLEANUP" == "true" ]]; then
    echo "========================================"
    log_info "Running cleanup..."
    echo ""

    for source in "${SOURCES_TO_SYNC[@]}"; do
        template=$(image_get_template_name "$IMAGES_CONFIG" "$source")
        import_dir=$(image_get_import_dir "$IMAGES_CONFIG" "$source")
        image_cleanup_old_versions "$template" "$import_dir" "$KEEP_VERSIONS" false
    done
    echo ""
fi

echo "========================================"

if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "Some sources failed to sync: ${failed[*]}"
    exit 1
else
    log_success "All image sources synced successfully"
fi
