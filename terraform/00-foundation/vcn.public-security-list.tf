resource "oci_core_security_list" "public" {
  compartment_id = var.oci_auth.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = var.vcn.public_security_list.name

  # Itera dinamicamente sobre as portas TCP definidas no objeto var.vcn
  # (HTTP, HTTPS — facil adicionar mais portas sem mexer no recurso)
  dynamic "ingress_security_rules" {
    for_each = var.vcn.public_security_list.ingress_tcp_ports
    content {
      protocol    = "6" # TCP
      source      = "0.0.0.0/0"
      description = ingress_security_rules.value.description
      tcp_options {
        min = ingress_security_rules.value.port
        max = ingress_security_rules.value.port
      }
    }
  }

  # Comunicação interna entre nodes (VCN inteira)
  ingress_security_rules {
    protocol    = "all"
    source      = var.vcn.cidr_block
    description = "Tráfego interno da VCN"
  }

  # Todo tráfego de saída liberado
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = var.tags
}
