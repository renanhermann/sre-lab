resource "oci_core_subnet" "private" {
  compartment_id             = var.oci_auth.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = var.vcn.private_subnet.cidr_block
  display_name               = var.vcn.private_subnet.name
  dns_label                  = var.vcn.private_subnet.dns_label
  prohibit_public_ip_on_vnic = var.vcn.private_subnet.prohibit_public_ip_on_vnic
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]

  freeform_tags = merge(var.tags, { Tier = "private" })
}
