# bjornetes

Deploy Kubernetes clusters on Proxmox using Chainguard VM images.

## Features

- Automated VM provisioning on Proxmox VE
- Kubernetes cluster bootstrap with kubeadm
- Single control plane cluster deployment
- Calico CNI networking
- MetalLB load balancer
- NFS persistent volume provisioner
- Chainguard hardened container images throughout

## Quick Start

```bash
# Copy example configuration files
cp config/cluster.yaml.example config/cluster.yaml
cp config/image-sources.yaml.example config/image-sources.yaml
cp config/metallb-config.yaml.example config/metallb-config.yaml

# Edit configs with your environment settings (see Configuration below)

# Sync Chainguard VM images to Proxmox
./scripts/image-sync.sh

# Provision VMs
./scripts/provision.sh

# Bootstrap Kubernetes
./scripts/bootstrap.sh

# Use the cluster
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

## Prerequisites

### Required

- **Proxmox VE** with SSH access (root or sudo user)
- **kubectl** for cluster management
- **helm** v3+ for installing components
- **yq** or Python 3 with PyYAML for config parsing
- **SSH key pair** (`~/.ssh/id_rsa` by default)

### Optional

- **chainctl** - Required for Chainguard private APK repository (latest Kubernetes versions)
  - Install: https://edu.chainguard.dev/chainguard/administration/how-to-install-chainctl/
  - Auth: `chainctl auth login`

- **gcloud** - Required for downloading VM images from GCS
  - Install: https://cloud.google.com/sdk/docs/install
  - Auth: `gcloud auth login`

## Configuration

### config/cluster.yaml

Core cluster settings. Key fields to customize:

```yaml
proxmox:
  host: "your-proxmox-host.example.com"
  storage: "your-storage-name"

network:
  gateway: "192.168.1.1"

nodes:
  control_plane:
    count: 1
    ip_start: "192.168.1.100"
  workers:
    count: 3
    ip_start: "192.168.1.110"

storage:
  nfs:
    server: 192.168.1.10
    path: /exports/k8s-volumes
```

| Key | Description |
|-----|-------------|
| `cluster.name` | Cluster name (used in kubeconfig) |
| `cluster.kubernetes_version` | Kubernetes minor version (e.g., "1.35") |
| `cluster.use_private_apk` | Use Chainguard private APK repo |
| `proxmox.host` | Proxmox SSH hostname |
| `proxmox.storage` | Storage for VM disks |
| `vm_defaults.vmid_start` | Starting VM ID |
| `nodes.control_plane.count` | Control plane nodes (1) |
| `nodes.workers.count` | Worker nodes |

### config/metallb-config.yaml

IP range for LoadBalancer services:

```yaml
spec:
  addresses:
  - 192.168.1.200-192.168.1.210
```

### config/versions.yaml

Component versions (usually no changes needed):

| Key | Description |
|-----|-------------|
| `images.registry` | Container image registry |
| `calico.version` | Calico CNI version |
| `metallb.version` | MetalLB version |
| `vm_ssh_user` | SSH user for VMs |

## Scripts

| Script | Description |
|--------|-------------|
| `image-sync.sh` | Download Chainguard VM images to Proxmox |
| `provision.sh` | Create and configure VMs (`--dry-run` available) |
| `bootstrap.sh` | Initialize Kubernetes cluster |
| `kubeconfig.sh` | Configure local kubectl |
| `test-cluster.sh` | Validate cluster functionality |
| `reset.sh` | Reset cluster (keeps VMs) |
| `destroy.sh` | Destroy all cluster VMs |
| `mirror-image.sh` | Copy container images between registries |
| `deploy-scanners.sh` | Deploy vulnerability scanner via Helm |
| `check-versions.sh` | Check for component updates (`--update` to apply) |

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Proxmox Host                      │
├──────────────────────────────────────────────────────┤
│  ┌────────────┐  ┌────────────┐  ┌────────────┐     │
│  │ Control    │  │ Worker 0   │  │ Worker 1   │ ... │
│  │ Plane      │  │            │  │            │     │
│  │            │  │            │  │            │     │
│  │ - kube-api │  │ - kubelet  │  │ - kubelet  │     │
│  │ - etcd     │  │ - proxy    │  │ - proxy    │     │
│  │ - scheduler│  │ - Calico   │  │ - Calico   │     │
│  │ - ctrl-mgr │  │            │  │            │     │
│  └────────────┘  └────────────┘  └────────────┘     │
│                                                      │
│  Networking: Calico CNI + MetalLB LoadBalancer      │
│  Storage: NFS persistent volumes                     │
└──────────────────────────────────────────────────────┘
```

## Troubleshooting

### SSH Connection Issues

```bash
# Verify Proxmox access
ssh root@your-proxmox-host
```

### Kubernetes Failures

```bash
# Check kubelet logs
ssh linky@<control-plane-ip>
sudo journalctl -u kubelet -f
```

### Reset and Retry

```bash
./scripts/reset.sh
./scripts/bootstrap.sh
```

### NFS Mount Issues

If NFS mounts fail with "Protocol not supported":
- Ensure `rpcbind` is running on nodes (bootstrap handles this)
- The provisioner uses `nolock` mount option to avoid locking issues

## Private APK Repository

For the latest Kubernetes versions (1.33+), enable the private APK repository:

```yaml
# config/cluster.yaml
cluster:
  use_private_apk: true
```

Requires `chainctl` authenticated with `chainctl auth login`.

Available versions: 1.31, 1.32, 1.33, 1.34, 1.35

## Known Limitations

**NFS CSI Driver**: The Chainguard `kubernetes-csi-driver-nfs` image has compatibility issues. The cluster uses `nfs-subdir-external-provisioner` instead, which works reliably.
