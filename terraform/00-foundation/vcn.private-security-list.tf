resource "oci_core_security_list" "private" {
  compartment_id = var.oci_auth.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = var.vcn.private_security_list.name

  # Comunicação interna liberada (nodes ↔ nodes, LB → nodes)
  ingress_security_rules {
    protocol    = "all"
    source      = var.vcn.cidr_block
    description = "Tráfego interno da VCN"
  }

  # ICMP para Path MTU Discovery (recomendado pelo OKE)
  ingress_security_rules {
    protocol    = "1" # ICMP
    source      = "0.0.0.0/0"
    description = "ICMP type 3 code 4 — Path MTU Discovery (OKE)"
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = var.tags
}
