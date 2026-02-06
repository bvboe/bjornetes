#!/usr/bin/env bash
# Image management functions

# Requires common.sh and proxmox.sh to be sourced first

# Get image source type
image_get_type() {
    local config_file="$1"
    local source_name="$2"

    yaml_get "$config_file" ".sources.${source_name}.type" ""
}

# Get image URL
image_get_url() {
    local config_file="$1"
    local source_name="$2"

    yaml_get "$config_file" ".sources.${source_name}.url" ""
}

# Get GCS bucket path
image_get_bucket_path() {
    local config_file="$1"
    local source_name="$2"

    yaml_get "$config_file" ".sources.${source_name}.bucket_path" ""
}

# Get file pattern for GCS downloads
image_get_file_pattern() {
    local config_file="$1"
    local source_name="$2"

    yaml_get "$config_file" ".sources.${source_name}.file_pattern" "*.qcow2"
}

# Get image checksum URL or value
image_get_checksum() {
    local config_file="$1"
    local source_name="$2"

    yaml_get "$config_file" ".sources.${source_name}.checksum" ""
}

# Get template name for image
image_get_template_name() {
    local config_file="$1"
    local source_name="$2"

    yaml_get "$config_file" ".sources.${source_name}.template_name" "$source_name"
}

# Get import directory for qcow2 files
image_get_import_dir() {
    local config_file="$1"
    local source_name="$2"

    local import_dir
    import_dir=$(yaml_get "$config_file" ".sources.${source_name}.import_dir" "")
    if [[ -z "$import_dir" ]]; then
        import_dir=$(yaml_get "$config_file" ".defaults.import_dir" "/mnt/pve/Wall-E-NFS/import")
    fi
    echo "$import_dir"
}

# Get storage for image
image_get_storage() {
    local config_file="$1"
    local source_name="$2"

    local storage
    storage=$(yaml_get "$config_file" ".sources.${source_name}.storage" "")

    if [[ -z "$storage" ]]; then
        storage=$(yaml_get "$config_file" ".defaults.storage" "local")
    fi

    echo "$storage"
}

# Get checksum type
image_get_checksum_type() {
    local config_file="$1"
    local source_name="$2"

    local checksum_type
    checksum_type=$(yaml_get "$config_file" ".sources.${source_name}.checksum_type" "")

    if [[ -z "$checksum_type" ]]; then
        checksum_type=$(yaml_get "$config_file" ".defaults.checksum_type" "sha256")
    fi

    echo "$checksum_type"
}

# List all configured image sources
image_list_sources() {
    local config_file="$1"

    yaml_keys "$config_file" ".sources"
}

# Download image from URL to Proxmox host
image_download_url() {
    local url="$1"
    local dest_path="$2"
    local checksum="${3:-}"
    local checksum_type="${4:-sha256}"

    log_info "Downloading image from $url..."

    # Download to Proxmox host
    pve_ssh "wget -q --show-progress -O '$dest_path' '$url'" || {
        log_error "Failed to download image"
        return 1
    }

    # Verify checksum if provided
    if [[ -n "$checksum" ]]; then
        image_verify_checksum "$dest_path" "$checksum" "$checksum_type"
    fi

    log_success "Image downloaded to $dest_path"
}

# Verify checksum of downloaded image
image_verify_checksum() {
    local file_path="$1"
    local checksum="$2"
    local checksum_type="$3"

    log_info "Verifying $checksum_type checksum..."

    local expected_checksum="$checksum"

    # If checksum looks like a URL, download it
    if [[ "$checksum" =~ ^https?:// ]]; then
        expected_checksum=$(pve_ssh "wget -qO- '$checksum'" | awk '{print $1}')
    fi

    # Calculate actual checksum
    local actual_checksum
    case "$checksum_type" in
        sha256)
            actual_checksum=$(pve_ssh "sha256sum '$file_path'" | awk '{print $1}')
            ;;
        sha512)
            actual_checksum=$(pve_ssh "sha512sum '$file_path'" | awk '{print $1}')
            ;;
        md5)
            actual_checksum=$(pve_ssh "md5sum '$file_path'" | awk '{print $1}')
            ;;
        none)
            log_warn "Checksum verification skipped"
            return 0
            ;;
        *)
            log_error "Unknown checksum type: $checksum_type"
            return 1
            ;;
    esac

    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        log_error "Checksum mismatch!"
        log_error "  Expected: $expected_checksum"
        log_error "  Actual:   $actual_checksum"
        return 1
    fi

    log_success "Checksum verified"
}

# Upload local image to Proxmox host
image_upload_local() {
    local local_path="$1"
    local remote_path="$2"

    log_info "Uploading image $local_path to Proxmox..."

    if [[ ! -f "$local_path" ]]; then
        log_error "Local image not found: $local_path"
        return 1
    fi

    pve_scp_to "$local_path" "$remote_path"

    log_success "Image uploaded to $remote_path"
}

# List all available versions in GCS bucket
# Returns version strings (one per line, sorted newest first)
image_gcs_list_versions() {
    local bucket_path="$1"

    require_cmd gcloud

    # List directories and extract version names
    gcloud storage ls "$bucket_path/" 2>/dev/null | grep -E "/$" | while read -r dir; do
        basename "${dir%/}"
    done | sort -r
}

# Get a specific version or latest from GCS bucket
# Sets GCS_LATEST_VERSION and GCS_LATEST_DIR variables
# Parameters:
#   $1 - bucket path
#   $2 - target version (optional, empty or "latest" for latest)
image_gcs_get_version() {
    local bucket_path="$1"
    local target_version="${2:-}"

    GCS_LATEST_VERSION=""
    GCS_LATEST_DIR=""

    require_cmd gcloud

    # List directories
    local dirs
    dirs=$(gcloud storage ls "$bucket_path/" 2>/dev/null | grep -E "/$") || {
        log_error "Failed to list GCS bucket or no directories found"
        return 1
    }

    if [[ -z "$dirs" ]]; then
        log_error "No directories found in $bucket_path"
        return 1
    fi

    if [[ -z "$target_version" || "$target_version" == "latest" ]]; then
        # Get latest version
        log_info "Checking latest version in $bucket_path..."
        GCS_LATEST_DIR=$(echo "$dirs" | sort -r | head -n 1)
    else
        # Find specific version (supports partial match like "20260121" for "20260121-0337")
        log_info "Looking for version '$target_version' in $bucket_path..."
        GCS_LATEST_DIR=$(echo "$dirs" | grep "/${target_version}" | sort -r | head -n 1)

        if [[ -z "$GCS_LATEST_DIR" ]]; then
            log_error "Version '$target_version' not found in bucket"
            log_info "Available versions:"
            echo "$dirs" | while read -r dir; do
                echo "  $(basename "${dir%/}")"
            done | sort -r | head -10
            return 1
        fi
    fi

    # Extract version from directory name
    GCS_LATEST_VERSION=$(basename "${GCS_LATEST_DIR%/}")

    log_info "Selected version: $GCS_LATEST_VERSION"
}

# Alias for backwards compatibility
image_gcs_get_latest_version() {
    image_gcs_get_version "$1" ""
}

# Download image from GCS bucket
# Downloads to local temp directory
# Sets IMAGE_DOWNLOAD_PATH variable with the local path
image_download_gcs() {
    local gcs_dir="$1"
    local file_pattern="$2"
    local local_dest_dir="$3"

    # Clear the result variable
    IMAGE_DOWNLOAD_PATH=""

    require_cmd gcloud

    # List files matching pattern in the directory
    log_info "Looking for files matching: $file_pattern"

    local files
    files=$(gcloud storage ls "${gcs_dir}${file_pattern}" 2>/dev/null) || {
        log_error "No files matching $file_pattern in $gcs_dir"
        return 1
    }

    if [[ -z "$files" ]]; then
        log_error "No files matching $file_pattern found"
        return 1
    fi

    # Download the qcow2 file(s)
    local qcow2_file
    qcow2_file=$(echo "$files" | grep -E "\.qcow2$" | head -n 1)

    if [[ -z "$qcow2_file" ]]; then
        log_error "No .qcow2 file found in $gcs_dir"
        return 1
    fi

    log_info "Downloading: $qcow2_file"

    gcloud storage cp "$qcow2_file" "$local_dest_dir/" || {
        log_error "Failed to download $qcow2_file"
        return 1
    }

    local filename
    filename=$(basename "$qcow2_file")

    log_success "Downloaded $filename to $local_dest_dir"

    # Set the result variable
    IMAGE_DOWNLOAD_PATH="${local_dest_dir}/${filename}"
}

# Import image and create template VM
image_create_template() {
    local image_path="$1"
    local template_name="$2"
    local storage="$3"
    local vmid="$4"

    log_info "Creating template VM $vmid ($template_name) from image..."

    # Create the VM
    pve_create_vm "$vmid" "$template_name" 2 2048 "$storage" 32 "vmbr0"

    # Import the disk and capture the output to get the disk reference
    log_info "Importing disk to VM $vmid..."
    local import_output
    import_output=$(pve_ssh "qm importdisk $vmid '$image_path' $storage 2>&1")
    echo "$import_output"

    # Parse the imported disk reference from output
    # Format: "unused0: successfully imported disk 'STORAGE:VMID/vm-VMID-disk-0.FORMAT'"
    local disk_ref
    disk_ref=$(echo "$import_output" | grep "successfully imported" | sed "s/.*'\([^']*\)'.*/\1/") || true

    if [[ -z "$disk_ref" ]]; then
        # Fallback: construct the reference for NFS storage
        disk_ref="${storage}:${vmid}/vm-${vmid}-disk-0.raw"
        log_warn "Could not parse disk reference, using: $disk_ref"
    fi

    log_info "Attaching disk: $disk_ref"

    # Attach the imported disk as scsi0 with iothread and set boot order
    pve_ssh "qm set $vmid --scsi0 '$disk_ref',iothread=1 --boot order=scsi0"

    log_success "Disk attached to VM $vmid"

    # Add EFI disk (must be after boot disk is attached)
    pve_add_efidisk "$vmid" "$storage"

    # Enable QEMU guest agent
    pve_ssh "qm set $vmid --agent enabled=1"

    # Convert to template
    pve_convert_to_template "$vmid"

    log_success "Template $template_name (VMID: $vmid) created"
}

# Sync a single image source
# Parameters:
#   $1 - images config file
#   $2 - cluster config file
#   $3 - source name
#   $4 - template VMID
#   $5 - target version (optional, empty or "latest" for latest)
image_sync_source() {
    local images_config="$1"
    local cluster_config="$2"
    local source_name="$3"
    local template_vmid="$4"
    local target_version="${5:-}"

    local source_type
    source_type=$(image_get_type "$images_config" "$source_name")

    if [[ -z "$source_type" ]]; then
        log_error "Unknown image source: $source_name"
        return 1
    fi

    local template_name
    template_name=$(image_get_template_name "$images_config" "$source_name")

    local storage
    storage=$(image_get_storage "$images_config" "$source_name")

    log_info "Syncing image source: $source_name (type: $source_type)"

    # For non-GCS sources, check if template VMID already exists
    # GCS sources check by versioned name instead (handled in gcs case)
    if [[ "$source_type" != "gcs" ]] && pve_vmid_exists "$template_vmid"; then
        log_warn "Template VMID $template_vmid already exists, skipping..."
        return 0
    fi

    # Verify storage exists
    if ! pve_storage_exists "$storage"; then
        log_error "Storage '$storage' does not exist on Proxmox"
        return 1
    fi

    # Create temp directory on Proxmox for downloads
    local remote_tmp
    remote_tmp=$(pve_ssh "mktemp -d")

    case "$source_type" in
        url)
            local url
            url=$(image_get_url "$images_config" "$source_name")

            if [[ -z "$url" ]]; then
                log_error "No URL configured for source: $source_name"
                return 1
            fi

            local checksum
            checksum=$(image_get_checksum "$images_config" "$source_name")

            local checksum_type
            checksum_type=$(image_get_checksum_type "$images_config" "$source_name")

            # Extract filename from URL
            local filename
            filename=$(basename "$url")
            local image_path="${remote_tmp}/${filename}"

            # Download image
            image_download_url "$url" "$image_path" "$checksum" "$checksum_type"

            # Create template
            image_create_template "$image_path" "$template_name" "$storage" "$template_vmid"
            ;;

        local)
            local local_path
            local_path=$(yaml_get "$images_config" ".sources.${source_name}.path" "")

            if [[ -z "$local_path" ]]; then
                log_error "No path configured for source: $source_name"
                return 1
            fi

            local_path=$(expand_path "$local_path")

            local filename
            filename=$(basename "$local_path")
            local remote_path="${remote_tmp}/${filename}"

            # Upload image
            image_upload_local "$local_path" "$remote_path"

            # Create template
            image_create_template "$remote_path" "$template_name" "$storage" "$template_vmid"
            ;;

        gcs)
            local bucket_path
            bucket_path=$(image_get_bucket_path "$images_config" "$source_name")

            if [[ -z "$bucket_path" ]]; then
                log_error "No bucket_path configured for source: $source_name"
                return 1
            fi

            local file_pattern
            file_pattern=$(image_get_file_pattern "$images_config" "$source_name")

            # Get import directory for qcow2 files
            local import_dir
            import_dir=$(image_get_import_dir "$images_config" "$source_name")

            # Get the target version from GCS (sets GCS_LATEST_VERSION and GCS_LATEST_DIR)
            image_gcs_get_version "$bucket_path" "$target_version" || {
                log_error "Failed to get version from GCS"
                return 1
            }

            # Create versioned filename (e.g., qemu-docker-full-amd64-20260122-0337.qcow2)
            local versioned_filename="${template_name}-${GCS_LATEST_VERSION}.qcow2"
            local import_path="${import_dir}/${versioned_filename}"

            # Check if this version already exists in import_dir (idempotency check)
            if pve_ssh "test -f '$import_path'" 2>/dev/null; then
                log_success "Image '$versioned_filename' already exists in $import_dir, skipping download"
                return 0
            fi

            log_info "New version found: $GCS_LATEST_VERSION"

            # Create local temp directory for download
            local local_tmp
            local_tmp=$(make_temp_dir)

            # Download from GCS to local machine (sets IMAGE_DOWNLOAD_PATH)
            image_download_gcs "$GCS_LATEST_DIR" "$file_pattern" "$local_tmp" || {
                log_error "Failed to download image from GCS"
                return 1
            }

            if [[ -z "$IMAGE_DOWNLOAD_PATH" || ! -f "$IMAGE_DOWNLOAD_PATH" ]]; then
                log_error "Download succeeded but image file not found"
                return 1
            fi

            # Upload directly to import directory with versioned name
            log_info "Uploading to $import_path..."
            image_upload_local "$IMAGE_DOWNLOAD_PATH" "$import_path"

            log_success "Image '$versioned_filename' imported to $import_dir"
            ;;

        oci)
            log_error "OCI registry source not yet implemented"
            return 1
            ;;

        *)
            log_error "Unknown source type: $source_type"
            return 1
            ;;
    esac

    # Cleanup temp directory
    pve_ssh "rm -rf '$remote_tmp'"

    log_success "Image source $source_name synced successfully"
}

# Get image for a cluster role
image_for_role() {
    local images_config="$1"
    local role="$2"

    yaml_get "$images_config" ".role_images.${role}" ""
}

# Cleanup old image versions, keeping the N most recent
# Parameters:
#   $1 - base template name (e.g., "qemu-docker-full-amd64")
#   $2 - import directory
#   $3 - number of versions to keep (default: 3)
#   $4 - dry run flag ("true" to just show what would be deleted)
image_cleanup_old_versions() {
    local base_name="$1"
    local import_dir="$2"
    local keep="${3:-3}"
    local dry_run="${4:-false}"

    log_info "Cleaning up old versions of '$base_name' in $import_dir (keeping $keep most recent)..."

    # List all qcow2 files matching the pattern, sorted by name (oldest first)
    local files
    files=$(pve_ssh "ls -1 ${import_dir}/${base_name}-*.qcow2 2>/dev/null | sort")

    if [[ -z "$files" ]]; then
        log_info "No images found matching '${base_name}-*.qcow2'"
        return 0
    fi

    # Count files
    local count
    count=$(echo "$files" | wc -l | tr -d ' ')

    log_info "Found $count image(s) matching '${base_name}-*.qcow2'"

    if [[ $count -le $keep ]]; then
        log_info "Nothing to clean up (have $count, keeping $keep)"
        return 0
    fi

    # Calculate how many to delete
    local to_delete=$((count - keep))

    log_info "Will delete $to_delete old version(s)"

    # Get the oldest files (first N lines, since sorted ascending by version)
    local old_files
    old_files=$(echo "$files" | head -n "$to_delete")

    local deleted=0

    while read -r filepath; do
        [[ -z "$filepath" ]] && continue

        local filename
        filename=$(basename "$filepath")

        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY RUN] Would delete: $filename"
        else
            log_info "Deleting: $filename"
            pve_ssh "rm -f '$filepath'"
            deleted=$((deleted + 1))
        fi
    done <<< "$old_files"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY RUN] Would delete $to_delete image(s)"
    else
        log_success "Deleted $deleted image(s)"
    fi
}

