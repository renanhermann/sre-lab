provider "oci" {
  tenancy_ocid     = var.oci_auth.tenancy_ocid
  user_ocid        = var.oci_auth.user_ocid
  fingerprint      = var.oci_auth.fingerprint
  private_key_path = var.oci_auth.private_key_path
  region           = var.region
}
