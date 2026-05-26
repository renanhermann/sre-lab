# Availability Domain disponível na região
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_auth.tenancy_ocid
}

# Imagens OKE válidas pra este cluster (já filtradas por versão K8s do cluster)
data "oci_containerengine_node_pool_option" "main" {
  node_pool_option_id = oci_containerengine_cluster.main.id
  compartment_id      = var.oci_auth.compartment_ocid
}
