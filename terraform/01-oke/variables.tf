variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type    = string
  default = "~/.oci/oci_api_key.pem"
}

variable "region" {
  type    = string
  default = "sa-saopaulo-1"
}

variable "compartment_ocid" {
  type = string
}

variable "vcn_id" {
  description = "OCID da VCN (output do 00-foundation)"
  type        = string
}

variable "public_subnet_id" {
  description = "OCID da subnet pública — API endpoint do cluster"
  type        = string
}

variable "private_subnet_id" {
  description = "OCID da subnet privada — nodes do OKE"
  type        = string
}

variable "project" {
  type    = string
  default = "sre-lab"
}

variable "k8s_version" {
  description = "Versão do Kubernetes no OKE"
  type        = string
  default     = "v1.30.1"
}

variable "node_shape" {
  description = "Shape dos nodes (ARM A1.Flex = Always Free eligible)"
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "node_ocpus" {
  description = "OCPUs por node (total free = 4 OCPUs)"
  type        = number
  default     = 2
}

variable "node_memory_gb" {
  description = "RAM por node em GB (total free = 24GB)"
  type        = number
  default     = 12
}

variable "node_count" {
  description = "Número de nodes no pool"
  type        = number
  default     = 2
}
