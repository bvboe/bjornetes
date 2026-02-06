#!/usr/bin/env bash
#
# test-cluster.sh - Validate Kubernetes cluster functionality
#
# Usage:
#   ./test-cluster.sh [options]
#
# Options:
#   -c, --config FILE    Path to cluster config (default: config/cluster.yaml)
#   -k, --kubeconfig     Path to kubeconfig (default: ./kubeconfig)
#   -h, --help           Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"

# Defaults
CLUSTER_CONFIG="$PROJECT_DIR/config/cluster.yaml"
KUBECONFIG_FILE="$PROJECT_DIR/kubeconfig"

usage() {
    head -12 "$0" | grep "^#" | cut -c 3-
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CLUSTER_CONFIG="$2"
            shift 2
            ;;
        -k|--kubeconfig)
            KUBECONFIG_FILE="$2"
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

[[ -f "$KUBECONFIG_FILE" ]] || die "Kubeconfig not found: $KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

test_pass() {
    local name="$1"
    log_success "PASS: $name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local name="$1"
    local reason="${2:-}"
    log_error "FAIL: $name"
    [[ -n "$reason" ]] && log_error "      $reason"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

cleanup() {
    log_info "Cleaning up test resources..."
    kubectl delete deployment test-nginx --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete svc test-nginx-lb --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete pod test-nfs-pod --ignore-not-found=true >/dev/null 2>&1 || true
    kubectl delete pvc test-nfs-pvc --ignore-not-found=true >/dev/null 2>&1 || true
    pkill -f "port-forward svc/test-nginx-lb" 2>/dev/null || true
}

trap cleanup EXIT

echo ""
log_info "=========================================="
log_info "Kubernetes Cluster Validation"
log_info "=========================================="
echo ""

# Test 1: Cluster connectivity
log_info "Test 1: Cluster connectivity"
if kubectl cluster-info >/dev/null 2>&1; then
    test_pass "Cluster connectivity"
else
    test_fail "Cluster connectivity" "Cannot connect to cluster"
fi

# Test 2: All nodes ready
log_info "Test 2: Node status"
NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready" || true)
if [[ -z "$NOT_READY" ]]; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
    test_pass "All $NODE_COUNT nodes are Ready"
else
    test_fail "Node status" "Some nodes not ready: $NOT_READY"
fi

# Test 3: Core system pods running
log_info "Test 3: Core system pods"
FAILED_PODS=$(kubectl get pods -n kube-system --no-headers | grep -v "Running\|Completed" || true)
if [[ -z "$FAILED_PODS" ]]; then
    test_pass "All kube-system pods running"
else
    test_fail "Core system pods" "Failed pods in kube-system"
    echo "$FAILED_PODS" | while read line; do log_error "      $line"; done
fi

# Test 4: CoreDNS resolution
log_info "Test 4: CoreDNS resolution"
if kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never --timeout=60s -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    test_pass "CoreDNS resolution"
else
    test_fail "CoreDNS resolution" "DNS lookup failed"
fi

# Test 5: MetalLB LoadBalancer
log_info "Test 5: MetalLB LoadBalancer"
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx-lb
spec:
  type: LoadBalancer
  selector:
    app: test-nginx
  ports:
  - port: 80
    targetPort: 80
EOF

# Wait for external IP
EXTERNAL_IP=""
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get svc test-nginx-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$EXTERNAL_IP" ]] && break
    sleep 1
done

if [[ -n "$EXTERNAL_IP" ]]; then
    # Wait for pod to be ready
    kubectl wait --for=condition=ready pod -l app=test-nginx --timeout=60s >/dev/null 2>&1 || true
    sleep 2

    if curl -s --connect-timeout 5 "http://${EXTERNAL_IP}" | grep -q "nginx"; then
        test_pass "MetalLB LoadBalancer (IP: $EXTERNAL_IP)"
    else
        test_fail "MetalLB LoadBalancer" "Got IP $EXTERNAL_IP but HTTP request failed"
    fi
else
    test_fail "MetalLB LoadBalancer" "No external IP assigned"
fi

# Test 6: Port forwarding
log_info "Test 6: Port forwarding"
kubectl port-forward svc/test-nginx-lb 18888:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 2

if curl -s --connect-timeout 5 http://localhost:18888 | grep -q "nginx"; then
    test_pass "Port forwarding"
else
    test_fail "Port forwarding" "Could not connect to localhost:18888"
fi
kill $PF_PID 2>/dev/null || true

# Test 7: NFS StorageClass exists
log_info "Test 7: NFS StorageClass"
if kubectl get storageclass nfs-client >/dev/null 2>&1; then
    test_pass "NFS StorageClass exists"
else
    test_fail "NFS StorageClass" "StorageClass 'nfs-client' not found"
fi

# Test 8: NFS dynamic provisioning
log_info "Test 8: NFS dynamic provisioning"
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-nfs-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
EOF

# Wait for PVC to bind
PVC_BOUND=false
for i in {1..30}; do
    STATUS=$(kubectl get pvc test-nfs-pvc -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$STATUS" == "Bound" ]]; then
        PVC_BOUND=true
        break
    fi
    sleep 1
done

if $PVC_BOUND; then
    test_pass "NFS dynamic provisioning"
else
    test_fail "NFS dynamic provisioning" "PVC did not bind within 30s"
fi

# Test 9: NFS mount works
log_info "Test 9: NFS mount and write"
if $PVC_BOUND; then
    kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-nfs-pod
spec:
  containers:
  - name: test
    image: busybox:1.36
    command: ["sh", "-c", "echo 'NFS works!' > /data/test.txt && cat /data/test.txt"]
    volumeMounts:
    - name: nfs-data
      mountPath: /data
  volumes:
  - name: nfs-data
    persistentVolumeClaim:
      claimName: test-nfs-pvc
  restartPolicy: Never
EOF

    # Wait for pod to complete
    POD_SUCCESS=false
    for i in {1..60}; do
        PHASE=$(kubectl get pod test-nfs-pod -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$PHASE" == "Succeeded" ]]; then
            POD_SUCCESS=true
            break
        elif [[ "$PHASE" == "Failed" ]]; then
            break
        fi
        sleep 1
    done

    if $POD_SUCCESS; then
        LOGS=$(kubectl logs test-nfs-pod 2>/dev/null || true)
        if [[ "$LOGS" == "NFS works!" ]]; then
            test_pass "NFS mount and write"
        else
            test_fail "NFS mount and write" "Unexpected output: $LOGS"
        fi
    else
        test_fail "NFS mount and write" "Pod did not complete successfully"
    fi
else
    test_fail "NFS mount and write" "Skipped (PVC not bound)"
fi

# Summary
echo ""
log_info "=========================================="
log_info "Test Summary"
log_info "=========================================="
echo ""
log_success "Passed: $TESTS_PASSED"
if [[ $TESTS_FAILED -gt 0 ]]; then
    log_error "Failed: $TESTS_FAILED"
    exit 1
else
    log_info "Failed: $TESTS_FAILED"
    echo ""
    log_success "All tests passed!"
    exit 0
fi
