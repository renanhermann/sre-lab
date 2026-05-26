resource "oci_core_subnet" "public" {
  compartment_id    = var.oci_auth.compartment_ocid
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = var.vcn.public_subnet.cidr_block
  display_name      = var.vcn.public_subnet.name
  dns_label         = var.vcn.public_subnet.dns_label
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]

  freeform_tags = merge(var.tags, { Tier = "public" })
}
