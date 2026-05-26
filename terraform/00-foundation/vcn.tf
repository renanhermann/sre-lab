resource "oci_core_vcn" "main" {
  compartment_id = var.oci_auth.compartment_ocid
  cidr_blocks    = [var.vcn.cidr_block]
  display_name   = var.vcn.name
  dns_label      = var.vcn.dns_label

  freeform_tags = var.tags
}
