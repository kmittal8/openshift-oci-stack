variable "compartment_ocid" {
  description = "OCI Compartment OCID where resources will be created"
  type        = string
}

variable "region" {
  description = "OCI Region"
  type        = string
  default     = "ap-sydney-1"
}

variable "availability_domain" {
  description = "Availability Domain name for compute instances"
  type        = string
}

variable "vcn_id" {
  description = "OCID of the existing VCN to deploy into"
  type        = string
}

variable "subnet_id" {
  description = "OCID of the existing public subnet for the cluster nodes"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key to be added to authorized_keys on all VMs"
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDcT5llgv93RLSIkCw85bpkWgQ318vtM/Pwpp5louXCffbe5bm9HINs1i7KFN80wf2dVA71K49eBYxIstm59E+DTcg7DIpW/gUxzF343DgV1zm25/a2wo2Du1nMhcpxSK96GXG33G5SREOJtASVVVviW8Bb58ozsioujc7kgUFIe8uEJEeAkKinF9OTBArvw/60SDOPp99AnmJViaKiTJnC/ZmgwFRoUlO1w0J4+EXS0vZRJbv3T7s7UV6kMHNq40avCc76N/ITnDxlApmtrWwxQMrOwqIXZ8Kks7qs001srCxxRdEmOaaeSViFkfOIymwDvdRCC7q8/tcOUsqqRuwx ssh-key-2025-11-16"
}

variable "my_public_ip" {
  description = "Your public IP address for SSH and Kubernetes API access (plain IP, no CIDR)"
  type        = string
  default     = "118.148.64.87"
}

variable "master_shape_ocpus" {
  description = "Number of OCPUs for the master node"
  type        = number
  default     = 2
}

variable "master_shape_memory_in_gbs" {
  description = "Memory in GB for the master node"
  type        = number
  default     = 6
}

variable "worker_shape_ocpus" {
  description = "Number of OCPUs per worker node"
  type        = number
  default     = 2
}

variable "worker_shape_memory_in_gbs" {
  description = "Memory in GB per worker node"
  type        = number
  default     = 4
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB for all nodes"
  type        = number
  default     = 50
}
