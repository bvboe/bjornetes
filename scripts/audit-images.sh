#!/usr/bin/env bash
#
# audit-images.sh - Verify every running container image is Chainguard-based
#
# Usage:
#   ./audit-images.sh [options]
#
# Options:
#   -k, --kubeconfig FILE  Path to kubeconfig (default: ./kubeconfig)
#   -i, --ignore REGEX     Ignore image refs matching REGEX (repeatable)
#   -h, --help             Show this help message
#
# Images pulled from the Chainguard registry pass on their reference alone.
# Images named registry.k8s.io/* are the ones bootstrap.sh retags locally, so the
# name proves nothing: the digest the kubelet resolved is compared against the
# Chainguard image that should be behind it. That comparison is what catches a
# control plane which quietly fell back to the upstream Debian-based images.
# It needs crane; without crane those images are reported as unverified rather
# than passed.
#
# Anything else fails the audit. Add-ons that are deliberately not from the
# Chainguard registry can be excluded, e.g.:
#   ./audit-images.sh --ignore '^ghcr\.io/bvboe/bjorn2scan/'
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/common.sh"

KUBECONFIG_FILE="$PROJECT_DIR/kubeconfig"
IGNORE_PATTERNS=()

usage() {
    head -25 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k | --kubeconfig)
            KUBECONFIG_FILE="$2"
            shift 2
            ;;
        -i | --ignore)
            IGNORE_PATTERNS+=("$2")
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ -f "$KUBECONFIG_FILE" ]] || die "Kubeconfig not found: $KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

load_versions

CAN_CHECK_DIGESTS=false
command -v crane &>/dev/null && CAN_CHECK_DIGESTS=true

# sha256 of stdin, for comparing against an image config digest
sha256_stdin() {
    if command -v sha256sum &>/dev/null; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

log_info "Auditing running images against ${CG_REGISTRY}"
$CAN_CHECK_DIGESTS || log_warn "crane not found - retagged registry.k8s.io images cannot be digest-verified"
echo ""

# One line per container: the reference from the pod spec, plus the imageID the
# kubelet resolved it to. The spec is the reliable source for the reference (the
# kubelet may report a retagged image under whichever name it prefers, and a
# digest-pinned image as a bare "sha256:..."), so the two are joined on the
# container name.
JOIN_TEMPLATE='
{{- range .items -}}
  {{- $cs := .status.containerStatuses -}}
  {{- $ics := .status.initContainerStatuses -}}
  {{- range .spec.containers -}}
    {{- $name := .name -}}{{.image}} {{range $cs}}{{if eq .name $name}}{{.imageID}}{{end}}{{end}}{{"\n"}}
  {{- end -}}
  {{- range .spec.initContainers -}}
    {{- $name := .name -}}{{.image}} {{range $ics}}{{if eq .name $name}}{{.imageID}}{{end}}{{end}}{{"\n"}}
  {{- end -}}
{{- end -}}'

RUNNING=$(kubectl get pods -A -o go-template="$JOIN_TEMPLATE" | sort -u)

CHAINGUARD=()
VERIFIED=()
FOREIGN=()
UNVERIFIED=()

while read -r ref image_id; do
    [[ -n "$ref" ]] || continue

    skip=false
    if [[ ${#IGNORE_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${IGNORE_PATTERNS[@]}"; do
            if [[ "$ref" =~ $pattern ]]; then
                skip=true
                break
            fi
        done
    fi
    if $skip; then
        continue
    fi

    # Pulled straight from the Chainguard registry
    if [[ "$ref" == "${CG_REGISTRY}"/* ]]; then
        CHAINGUARD+=("$ref")
        continue
    fi

    # Locally retagged control plane images: trust the digest, not the name
    if [[ "$ref" == registry.k8s.io/* ]]; then
        expected=$(cg_image_for "$ref")
        if [[ -z "$expected" ]]; then
            FOREIGN+=("$ref (no Chainguard image published)")
            continue
        fi
        if ! $CAN_CHECK_DIGESTS; then
            UNVERIFIED+=("$ref (expected to be $expected)")
            continue
        fi
        if [[ -z "$image_id" ]]; then
            UNVERIFIED+=("$ref (kubelet reported no imageID)")
            continue
        fi

        # An image pulled under its own name keeps the registry's manifest
        # digest; one that was retagged locally only reports its config digest.
        if [[ "$image_id" == *@* ]]; then
            actual="${image_id##*@}"
            expected_digest=$(crane digest "$expected" 2>/dev/null || true)
        else
            actual="${image_id#sha256:}"
            expected_digest=$(crane config "$expected" --platform linux/amd64 2>/dev/null | sha256_stdin || true)
            actual="sha256:${actual}"
            expected_digest="sha256:${expected_digest}"
        fi

        if [[ "$expected_digest" == "sha256:" || -z "$expected_digest" ]]; then
            UNVERIFIED+=("$ref (could not read digest of $expected)")
        elif [[ "$actual" == "$expected_digest" ]]; then
            VERIFIED+=("$ref -> $expected")
        else
            FOREIGN+=("$ref (does not match $expected - pulled from upstream)")
        fi
        continue
    fi

    FOREIGN+=("$ref")
done <<< "$RUNNING"

# The pause image backs every pod's sandbox but appears in no pod spec, so it is
# audited from the per-node image lists instead.
SANDBOX_EXPECTED=$(cg_image_for "registry.k8s.io/pause:sandbox")
NODE_IMAGES=$(kubectl get nodes -o go-template='
{{- range .items -}}
  {{- $node := .metadata.name -}}
  {{- range .status.images -}}
    {{- range .names -}}{{$node}} {{.}}{{"\n"}}{{- end -}}
  {{- end -}}
{{- end -}}')

while read -r node; do
    [[ -n "$node" ]] || continue

    names=$(printf '%s\n' "$NODE_IMAGES" | awk -v n="$node" '$1 == n {print $2}' | grep '/pause' || true)
    if [[ -z "$names" ]]; then
        UNVERIFIED+=("pause sandbox on $node (no pause image reported by the node)")
        continue
    fi

    # Pulled from the Chainguard registry, or retagged and identifiable by digest
    if printf '%s\n' "$names" | grep -q "^${CG_REGISTRY}/kubernetes-pause"; then
        CHAINGUARD+=("pause sandbox on $node (${SANDBOX_EXPECTED})")
        continue
    fi

    node_digest=$(printf '%s\n' "$names" | grep -m1 '@sha256:' | sed 's/.*@/@/' | tr -d '@' || true)
    if ! $CAN_CHECK_DIGESTS || [[ -z "$node_digest" ]]; then
        UNVERIFIED+=("pause sandbox on $node ($(printf '%s' "$names" | head -1), expected ${SANDBOX_EXPECTED})")
        continue
    fi

    expected_digest=$(crane digest "$SANDBOX_EXPECTED" 2>/dev/null || true)
    if [[ -z "$expected_digest" ]]; then
        UNVERIFIED+=("pause sandbox on $node (could not read digest of ${SANDBOX_EXPECTED})")
    elif [[ "$node_digest" == "$expected_digest" ]]; then
        VERIFIED+=("pause sandbox on $node -> ${SANDBOX_EXPECTED}")
    else
        FOREIGN+=("pause sandbox on $node (does not match ${SANDBOX_EXPECTED} - pulled from upstream)")
    fi
done <<< "$(kubectl get nodes -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}')"

if [[ ${#CHAINGUARD[@]} -gt 0 ]]; then
    log_success "Chainguard images (${#CHAINGUARD[@]}):"
    for ref in "${CHAINGUARD[@]}"; do printf "  %s\n" "$ref"; done
    echo ""
fi

if [[ ${#VERIFIED[@]} -gt 0 ]]; then
    log_success "Retagged and digest-verified as Chainguard (${#VERIFIED[@]}):"
    for ref in "${VERIFIED[@]}"; do printf "  %s\n" "$ref"; done
    echo ""
fi

if [[ ${#UNVERIFIED[@]} -gt 0 ]]; then
    log_warn "Could not verify (${#UNVERIFIED[@]}):"
    for ref in "${UNVERIFIED[@]}"; do printf "  %s\n" "$ref"; done
    echo ""
fi

if [[ ${#FOREIGN[@]} -gt 0 ]]; then
    log_error "Not Chainguard (${#FOREIGN[@]}):"
    for ref in "${FOREIGN[@]}"; do printf "  %s\n" "$ref"; done
    echo ""
    die "Cluster is not running on Chainguard images only"
fi

log_success "All audited images are Chainguard-based"
