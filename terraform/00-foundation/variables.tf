# ============================================================
# Variáveis de autenticação OCI
# Valores definidos em terraform.tfvars (gitignored)
# ============================================================

variable "tenancy_ocid" {
  description = "OCID da tenancy OCI"
  type        = string
}

variable "user_ocid" {
  description = "OCID do usuário OCI"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint da API key"
  type        = string
}

variable "private_key_path" {
  description = "Caminho da chave privada OCI (~/.oci/oci_api_key.pem)"
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "Região OCI"
  type        = string
  default     = "sa-saopaulo-1"
}

variable "compartment_ocid" {
  description = "OCID do compartment (use o root = tenancy_ocid)"
  type        = string
}

# ============================================================
# Variáveis de rede
# ============================================================

variable "vcn_cidr" {
  description = "CIDR block da VCN"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR da subnet pública (load balancers)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR da subnet privada (nodes OKE)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "project" {
  description = "Nome do projeto (usado em tags e nomes)"
  type        = string
  default     = "sre-lab"
}
