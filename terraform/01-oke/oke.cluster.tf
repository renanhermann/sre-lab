resource "oci_containerengine_cluster" "main" {
  compartment_id     = var.oci_auth.compartment_ocid
  kubernetes_version = var.cluster.k8s_version
  name               = var.cluster.name
  vcn_id             = var.network.vcn_id

  endpoint_config {
    # API server acessível pela internet (com auth via kubeconfig)
    is_public_ip_enabled = true
    subnet_id            = var.network.public_subnet_id
  }

  options {
    service_lb_subnet_ids = [var.network.public_subnet_id]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = var.cluster.pods_cidr
      services_cidr = var.cluster.services_cidr
    }
  }

  freeform_tags = var.tags
}
