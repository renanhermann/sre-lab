output "cluster_id" {
  description = "OCID do cluster OKE"
  value       = oci_containerengine_cluster.main.id
}

output "cluster_kubernetes_version" {
  description = "Versão do Kubernetes no cluster"
  value       = oci_containerengine_cluster.main.kubernetes_version
}

output "node_pool_id" {
  description = "OCID do node pool"
  value       = oci_containerengine_node_pool.main.id
}

output "kubeconfig_command" {
  description = "Comando para baixar o kubeconfig do cluster"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.main.id} --file ~/.kube/config-oci --region ${var.region} --token-version 2.0.0"
}
