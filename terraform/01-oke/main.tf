terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

# ============================================================
# Data Sources
# ============================================================

# Availability Domain disponível na região
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Imagem ARM Oracle Linux 8 mais recente para OKE
data "oci_core_images" "oke_node" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.node_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = [".*OKE.*"]
    regex  = true
  }
}

# ============================================================
# OKE Cluster
# ============================================================

resource "oci_containerengine_cluster" "main" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.k8s_version
  name               = "${var.project}-cluster"
  vcn_id             = var.vcn_id

  endpoint_config {
    # API server acessível pela internet (com auth)
    is_public_ip_enabled = true
    subnet_id            = var.public_subnet_id
  }

  options {
    service_lb_subnet_ids = [var.public_subnet_id]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }

  freeform_tags = {
    project = var.project
    env     = "lab"
  }
}

# ============================================================
# Node Pool — ARM Ampere A1 (Always Free eligible)
# 2 nodes × 2 OCPUs × 12GB = 4 OCPUs + 24GB (limite free tier)
# ============================================================

resource "oci_containerengine_node_pool" "main" {
  cluster_id         = oci_containerengine_cluster.main.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.k8s_version
  name               = "${var.project}-nodepool"

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = var.private_subnet_id
    }

    freeform_tags = {
      project = var.project
    }
  }

  node_shape = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gb
  }

  node_source_details {
    image_id    = data.oci_core_images.oke_node.images[0].id
    source_type = "IMAGE"

    # Boot volume de 50GB por node
    boot_volume_size_in_gbs = 50
  }

  initial_node_labels {
    key   = "project"
    value = var.project
  }

  freeform_tags = {
    project = var.project
    env     = "lab"
  }
}
