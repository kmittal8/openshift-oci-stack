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
  kubeadm_token = "${random_string.token_prefix.result}.${random_string.token_suffix.result}"
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
# Network Security Group — attached to all 3 nodes
# We use a new NSG rather than modifying the existing security list
# ---------------------------------------------------------------------------
resource "oci_core_network_security_group" "k8s_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = var.vcn_id
  display_name   = "k8s-cluster-nsg"
}

# SSH from user's public IP
resource "oci_core_network_security_group_security_rule" "allow_ssh" {
  network_security_group_id = oci_core_network_security_group.k8s_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${var.my_public_ip}/32"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# K8s API server from user's public IP
resource "oci_core_network_security_group_security_rule" "allow_k8s_api" {
  network_security_group_id = oci_core_network_security_group.k8s_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${var.my_public_ip}/32"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

# All traffic between cluster nodes (self-referencing NSG)
resource "oci_core_network_security_group_security_rule" "allow_internal_ingress" {
  network_security_group_id = oci_core_network_security_group.k8s_nsg.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.k8s_nsg.id
  source_type               = "NETWORK_SECURITY_GROUP"
}

# All outbound traffic (for apt, kubeadm image pulls, Calico, etc.)
resource "oci_core_network_security_group_security_rule" "allow_all_egress" {
  network_security_group_id = oci_core_network_security_group.k8s_nsg.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
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
    subnet_id        = var.subnet_id
    assign_public_ip = true
    display_name     = "k8s-master-vnic"
    nsg_ids          = [oci_core_network_security_group.k8s_nsg.id]
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
# will create them only after master's private IP is known.
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
    subnet_id        = var.subnet_id
    assign_public_ip = true
    display_name     = "k8s-worker-${count.index + 1}-vnic"
    nsg_ids          = [oci_core_network_security_group.k8s_nsg.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data = base64encode(templatefile("${path.module}/userdata/worker.sh.tpl", {
      kubeadm_token     = local.kubeadm_token
      master_private_ip = oci_core_instance.master.private_ip
    }))
  }
}
