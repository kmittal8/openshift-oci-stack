terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0.0"
    }
  }
}

provider "oci" {
  region = var.region
}

# ---------------------------------------------------------------------------
# Kubeadm token — generated once at apply time, injected into all cloud-init
# Format required by kubeadm: [a-z0-9]{6}.[a-z0-9]{16}
# ---------------------------------------------------------------------------
resource "random_string" "token_prefix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "random_string" "token_suffix" {
  length  = 16
  special = false
  upper   = false
  numeric = true
}

locals {
  kubeadm_token   = "${random_string.token_prefix.result}.${random_string.token_suffix.result}"
  k8s_subnet_cidr = cidrsubnet(data.oci_core_vcn.existing.cidr_block, 8, 100)
}

# ---------------------------------------------------------------------------
# Look up the most recent Ubuntu 22.04 image for VM.Standard.E4.Flex (x86_64)
# ---------------------------------------------------------------------------
data "oci_core_images" "ubuntu_22_04" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "22.04"
  shape                    = "VM.Standard.E4.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------
# Read the existing VCN
# ---------------------------------------------------------------------------
data "oci_core_vcn" "existing" {
  vcn_id = var.vcn_id
}

# Look up the Internet Gateway in the VCN
# (the default route table may point to LPG — we need IGW for public internet)
data "oci_core_internet_gateways" "igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  state          = "AVAILABLE"
}

# Dedicated route table for the K8s subnet — routes all traffic via IGW
resource "oci_core_route_table" "k8s_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "k8s-cluster-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = data.oci_core_internet_gateways.igw.gateways[0].id
  }
}

# ---------------------------------------------------------------------------
# New K8s Security List — contains only K8s-specific rules
# Your existing SL (var.existing_security_list_id) is also attached to the
# subnet so its rules are preserved untouched.
# ---------------------------------------------------------------------------
resource "oci_core_security_list" "k8s_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "k8s-cluster-sl"

  # SSH from your public IP only
  ingress_security_rules {
    protocol  = "6"
    source    = "${var.my_public_ip}/32"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Kubernetes API server from your public IP only
  ingress_security_rules {
    protocol  = "6"
    source    = "${var.my_public_ip}/32"
    stateless = false
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # All traffic within the K8s subnet (node-to-node: kubelet, etcd, Calico, etc.)
  ingress_security_rules {
    protocol  = "all"
    source    = local.k8s_subnet_cidr
    stateless = false
  }

  # All outbound traffic (apt, image pulls, Calico, etc.)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# ---------------------------------------------------------------------------
# Dedicated subnet for the K8s cluster
# Attaches both: existing SL (preserved) + new K8s SL (our rules)
# Uses the VCN's default route table so internet access works out of the box
# ---------------------------------------------------------------------------
resource "oci_core_subnet" "k8s_subnet" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  cidr_block     = local.k8s_subnet_cidr
  display_name   = "k8s-cluster-subnet"
  route_table_id = oci_core_route_table.k8s_rt.id
  security_list_ids = [oci_core_security_list.k8s_sl.id]
}

# ---------------------------------------------------------------------------
# Master Node
# ---------------------------------------------------------------------------
resource "oci_core_instance" "master" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "k8s-master"
  shape               = "VM.Standard.E4.Flex"

  shape_config {
    ocpus         = var.master_shape_ocpus
    memory_in_gbs = var.master_shape_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_22_04.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.k8s_subnet.id
    assign_public_ip = true
    display_name     = "k8s-master-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/userdata/master.sh.tpl", {
      kubeadm_token = local.kubeadm_token
    }))
  }
}

# ---------------------------------------------------------------------------
# Worker Nodes (2)
# Workers depend on master (via master.private_ip reference) so Terraform
# creates them only after master's private IP is known.
# ---------------------------------------------------------------------------
resource "oci_core_instance" "worker" {
  count               = 2
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "k8s-worker-${count.index + 1}"
  shape               = "VM.Standard.E4.Flex"

  shape_config {
    ocpus         = var.worker_shape_ocpus
    memory_in_gbs = var.worker_shape_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_22_04.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.k8s_subnet.id
    assign_public_ip = true
    display_name     = "k8s-worker-${count.index + 1}-vnic"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/userdata/worker.sh.tpl", {
      kubeadm_token     = local.kubeadm_token
      master_private_ip = oci_core_instance.master.private_ip
    }))
  }
}
