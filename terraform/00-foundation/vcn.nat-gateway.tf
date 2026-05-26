resource "oci_core_nat_gateway" "nat" {
  compartment_id = var.oci_auth.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = var.vcn.nat_gateway_name

  freeform_tags = var.tags
}
