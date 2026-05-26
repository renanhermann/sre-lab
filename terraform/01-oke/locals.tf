locals {
  # Detecta arquitetura pelo prefixo do shape (ARM Ampere começa com A)
  is_arm = can(regex("^VM\\.Standard\\.A[0-9]", var.node_pool.shape))

  # Detecta se shape tem GPU (BM.GPU.* ou VM.GPU.*)
  has_gpu = can(regex("GPU", var.node_pool.shape))

  # Filtra imagens OKE válidas:
  #   1. Arquitetura correta (aarch64 só pra ARM)
  #   2. GPU images só pra shapes GPU
  #   3. Oracle Linux 8 (excluir 7.9 legacy)
  valid_images = [
    for s in data.oci_containerengine_node_pool_option.main.sources :
    s if(
      (local.is_arm ? can(regex("aarch64", s.source_name)) : !can(regex("aarch64", s.source_name))) &&
      (local.has_gpu ? can(regex("GPU", s.source_name)) : !can(regex("GPU", s.source_name))) &&
      can(regex("Oracle-Linux-8", s.source_name))
    )
  ]

  # Primeira imagem da lista (já vem ordenada da mais recente)
  node_image_id = local.valid_images[0].image_id
}
