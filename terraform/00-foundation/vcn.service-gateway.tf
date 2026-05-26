resource "oci_core_service_gateway" "svcgw" {
  compartment_id = var.oci_auth.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = var.vcn.service_gateway_name

  services {
    service_id = data.oci_core_services.all.services[0].id
  }

  freeform_tags = var.tags
}
