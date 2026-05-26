resource "oci_core_route_table" "private" {
  compartment_id = var.oci_auth.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = var.vcn.private_route_table

  route_rules {
    network_entity_id = oci_core_nat_gateway.nat.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }

  route_rules {
    network_entity_id = oci_core_service_gateway.svcgw.id
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
  }

  freeform_tags = var.tags
}
