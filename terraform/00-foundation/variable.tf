# ============================================================
# Credentials OCI — sempre via terraform.tfvars (gitignored)
# ============================================================

variable "oci_auth" {
  description = "Credenciais e identificação OCI (preenchido em terraform.tfvars)"
  type = object({
    tenancy_ocid     = string
    user_ocid        = string
    fingerprint      = string
    private_key_path = string
    compartment_ocid = string
  })
}

variable "region" {
  type    = string
  default = "sa-saopaulo-1"
}

# ============================================================
# VCN — configuração completa em um único objeto tipado
# ============================================================

variable "vcn" {
  type = object({
    cidr_block            = string
    name                  = string
    dns_label             = string
    internet_gateway_name = string
    nat_gateway_name      = string
    service_gateway_name  = string
    public_route_table    = string
    private_route_table   = string

    public_subnet = object({
      name       = string
      cidr_block = string
      dns_label  = string
    })

    private_subnet = object({
      name                       = string
      cidr_block                 = string
      dns_label                  = string
      prohibit_public_ip_on_vnic = bool
    })

    public_security_list = object({
      name = string
      ingress_tcp_ports = list(object({
        port        = number
        description = string
      }))
    })

    private_security_list = object({
      name = string
    })
  })

  default = {
    cidr_block            = "10.0.0.0/16"
    name                  = "sre-lab-vcn"
    dns_label             = "srelab"
    internet_gateway_name = "sre-lab-igw"
    nat_gateway_name      = "sre-lab-nat"
    service_gateway_name  = "sre-lab-svcgw"
    public_route_table    = "sre-lab-rt-public"
    private_route_table   = "sre-lab-rt-private"

    public_subnet = {
      name       = "sre-lab-subnet-public"
      cidr_block = "10.0.1.0/24"
      dns_label  = "public"
    }

    private_subnet = {
      name                       = "sre-lab-subnet-private"
      cidr_block                 = "10.0.2.0/24"
      dns_label                  = "private"
      prohibit_public_ip_on_vnic = true
    }

    public_security_list = {
      name = "sre-lab-sl-public"
      ingress_tcp_ports = [
        { port = 443, description = "HTTPS de entrada (Load Balancers)" },
        { port = 80, description = "HTTP de entrada (Load Balancers)" },
        { port = 6443, description = "Kubernetes API server (kubectl)" },
      ]
    }

    private_security_list = {
      name = "sre-lab-sl-private"
    }
  }
}

variable "tags" {
  type = map(string)
  default = {
    ManagedBy = "terraform"
    Project   = "sre-lab"
    Env       = "lab"
  }
}
