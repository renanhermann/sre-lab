resource "oci_containerengine_node_pool" "main" {
  cluster_id         = oci_containerengine_cluster.main.id
  compartment_id     = var.oci_auth.compartment_ocid
  kubernetes_version = var.cluster.k8s_version
  name               = var.node_pool.name

  node_config_details {
    size = var.node_pool.count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = var.network.private_subnet_id
    }

    freeform_tags = var.tags
  }

  node_shape = var.node_pool.shape

  node_shape_config {
    ocpus         = var.node_pool.ocpus
    memory_in_gbs = var.node_pool.memory_gb
  }

  node_source_details {
    image_id                = local.node_image_id
    source_type             = "IMAGE"
    boot_volume_size_in_gbs = var.node_pool.boot_volume_gb
  }

  initial_node_labels {
    key   = "project"
    value = "sre-lab"
  }

  freeform_tags = var.tags
}
