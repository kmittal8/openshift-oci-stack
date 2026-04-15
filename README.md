# k8s-oci-stack

Terraform stack for deploying a 3-node Kubernetes cluster on Oracle Cloud Infrastructure (OCI) using the OCI Resource Manager.

## Architecture

| Node | Role | Shape | OCPUs | RAM |
|------|------|-------|-------|-----|
| k8s-master | Control plane | VM.Standard.E4.Flex | 2 | 6 GB |
| k8s-worker-1 | Data plane | VM.Standard.E4.Flex | 2 | 4 GB |
| k8s-worker-2 | Data plane | VM.Standard.E4.Flex | 2 | 4 GB |

**Stack:**
- OS: Ubuntu 22.04
- Container runtime: CRI-O v1.32
- Kubernetes: v1.32
- CNI: Calico v3.29
- Region: ap-sydney-1

## How It Works

1. Terraform provisions 3 Ubuntu VMs and a Network Security Group inside your existing VCN
2. A kubeadm token is generated at apply time and injected into all cloud-init scripts
3. Master node initialises the cluster with `kubeadm init` and deploys Calico
4. Worker nodes poll the master API (`port 6443`) until it is ready, then auto-join using the pre-shared token — no manual SSH step required

## Security

- SSH (port 22) and K8s API (port 6443) are restricted to your public IP via a dedicated NSG
- No passwords or private keys are stored in this repository
- A new NSG is created on each apply — the existing VCN security list is not modified

## Deploy via OCI Resource Manager

### Prerequisites
- An existing OCI VCN with a public subnet
- A GitHub Personal Access Token with `repo` scope (for the source provider)

### Steps

1. **Create a configuration source provider**
   - OCI Console → Resource Manager → Configuration Source Providers → Create
   - Type: GitHub, URL: `https://github.com`, Repo: `kmittal8/k8s-oci-stack`, Branch: `main`

2. **Create a stack**
   - Resource Manager → Stacks → Create Stack
   - Choose **Source code control system** → select the provider above
   - Fill in the variables (dropdowns auto-populate from your tenancy):

   | Variable | Description |
   |----------|-------------|
   | Compartment | OCI compartment to deploy into |
   | Availability Domain | AD for compute instances |
   | VCN | Existing VCN |
   | Subnet | Existing public subnet |
   | SSH Public Key | Public key for VM access (pre-filled with `vibe.key.pub`) |
   | Your Public IP | Only this IP can SSH in and reach the K8s API |

3. **Plan → Apply**
   - Click **Plan**, wait for `Succeeded`
   - Click **Apply** — provisioning takes ~5–8 minutes

### After Apply

The **Outputs** tab shows the public IPs and a ready-to-use SSH command.

```bash
# SSH into master
ssh -i ~/.ssh/vibe.key ubuntu@<master_public_ip>

# Verify all nodes are ready (run on master)
kubectl get nodes -o wide

# Check system pods
kubectl get pods -n kube-system
```

Expected output:
```
NAME           STATUS   ROLES           AGE   VERSION
k8s-master     Ready    control-plane   8m    v1.32.x
k8s-worker-1   Ready    <none>          6m    v1.32.x
k8s-worker-2   Ready    <none>          6m    v1.32.x
```

## File Structure

```
.
├── main.tf                   # NSG, compute instances, kubeadm token
├── variables.tf              # Input variables
├── outputs.tf                # Public IPs and SSH command
├── schema.yaml               # OCI Resource Manager UI schema
└── userdata/
    ├── master.sh.tpl         # Cloud-init: control plane setup
    └── worker.sh.tpl         # Cloud-init: worker setup + auto-join
```

## Troubleshooting

**Workers not joining after 10 minutes**
```bash
# Check cloud-init log on a worker
ssh -i ~/.ssh/vibe.key ubuntu@<worker_public_ip>
sudo tail -f /var/log/k8s-worker-init.log
```

**Master init failed**
```bash
ssh -i ~/.ssh/vibe.key ubuntu@<master_public_ip>
sudo tail -f /var/log/k8s-master-init.log
```

**Reset and retry a node**
```bash
sudo kubeadm reset -f
# Then re-run the relevant cloud-init steps manually
```
