#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/k8s-master-init.log) 2>&1

echo "=== [$(date)] Starting Kubernetes Master Node Setup ==="

# --- 1. Allow intra-cluster traffic (OCI Ubuntu image has a REJECT rule by default) ---
iptables -I INPUT -s 192.168.0.0/16 -j ACCEPT

# --- 2. Disable swap (required by kubelet) ---
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# --- 2. Load required kernel modules ---
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# --- 3. Sysctl settings for Kubernetes networking ---
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# --- 4. Stop unattended-upgrades and wait for APT to be fully free ---
echo "Stopping unattended-upgrades..."
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
while pgrep -x unattended-upgr > /dev/null || pgrep -x apt-get > /dev/null || pgrep -x dpkg > /dev/null; do
  echo "[$(date)] Waiting for apt/dpkg processes to exit..."
  sleep 5
done
echo "[$(date)] APT free."

# --- 4. Install CRI-O v1.32 container runtime ---
CRIO_VERSION=v1.32
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" \
  > /etc/apt/sources.list.d/cri-o.list

apt-get update -y
apt-get install -y cri-o
systemctl enable --now crio
echo "CRI-O status: $(systemctl is-active crio)"

# --- 5. Install Kubernetes v1.32 (kubelet, kubeadm, kubectl) ---
KUBERNETES_VERSION=v1.32
curl -fsSL "https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key" \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet

# --- 6. Initialize the Kubernetes control plane ---
MASTER_PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo "Master private IP detected: $MASTER_PRIVATE_IP"

kubeadm init \
  --apiserver-advertise-address="$MASTER_PRIVATE_IP" \
  --pod-network-cidr=192.168.0.0/16 \
  --token "${kubeadm_token}" \
  --token-ttl 0

# --- 7. Set up kubeconfig for the ubuntu user ---
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

# Also make kubectl work for root in this script
export KUBECONFIG=/etc/kubernetes/admin.conf

# --- 8. Deploy Calico CNI ---
echo "Installing Calico CNI..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml

echo "=== [$(date)] Master Node Setup Complete ==="
echo "Cluster initialized with token: ${kubeadm_token}"
echo "Workers will poll this node and auto-join using the pre-shared token."
echo "Monitor worker join progress: tail -f /var/log/k8s-worker-init.log (on each worker)"
