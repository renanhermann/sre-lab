# ============================================================
# Credentials OCI (mesmo padrão do 00-foundation)
# ============================================================

variable "oci_auth" {
  description = "Credenciais e identificação OCI"
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
# Rede — IDs vêm dos outputs do 00-foundation
# ============================================================

variable "network" {
  description = "OCIDs da VCN e subnets criadas no módulo 00-foundation"
  type = object({
    vcn_id            = string
    public_subnet_id  = string
    private_subnet_id = string
  })
}

# ============================================================
# Cluster OKE
# ============================================================

variable "cluster" {
  description = "Configuração do cluster OKE"
  type = object({
    name          = string
    k8s_version   = string
    pods_cidr     = string
    services_cidr = string
  })

  default = {
    name          = "sre-lab-cluster"
    k8s_version   = "v1.32.1"
    pods_cidr     = "10.244.0.0/16"
    services_cidr = "10.96.0.0/16"
  }
}

# ============================================================
# Node Pool
# ============================================================

variable "node_pool" {
  description = "Configuração do node pool (shape, recursos, quantidade)"
  type = object({
    name           = string
    shape          = string
    ocpus          = number
    memory_gb      = number
    count          = number
    boot_volume_gb = number
  })

  default = {
    name           = "sre-lab-nodepool"
    shape          = "VM.Standard3.Flex" # Intel Xeon — pool de capacidade diferente
    ocpus          = 2
    memory_gb      = 8
    count          = 2
    boot_volume_gb = 50
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
