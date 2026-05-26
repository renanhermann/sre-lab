resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.oci_auth.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = var.vcn.internet_gateway_name
  enabled        = true

  freeform_tags = var.tags
}
