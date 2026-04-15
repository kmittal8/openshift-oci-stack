output "master_public_ip" {
  description = "Public IP of the Kubernetes master node"
  value       = oci_core_instance.master.public_ip
}

output "master_private_ip" {
  description = "Private IP of the Kubernetes master node"
  value       = oci_core_instance.master.private_ip
}

output "worker_1_public_ip" {
  description = "Public IP of worker node 1"
  value       = oci_core_instance.worker[0].public_ip
}

output "worker_2_public_ip" {
  description = "Public IP of worker node 2"
  value       = oci_core_instance.worker[1].public_ip
}

output "ssh_command_master" {
  description = "SSH command to connect to the master node"
  value       = "ssh -i ~/.ssh/vibe.key ubuntu@${oci_core_instance.master.public_ip}"
}

output "verify_cluster" {
  description = "Run this on the master to check all nodes are ready"
  value       = "kubectl get nodes -o wide"
}
