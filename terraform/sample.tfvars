location                  = "westus2"
vnet_address_space        = ["10.240.0.0/16"]
snet_aks_address_space    = ["10.240.0.0/24"]
snet_agw_address_space    = ["10.240.1.0/24"]
kubernetes_version        = "1.21.2"
default_node_pool_vm_size = "Standard_B2ms"
cluster_node_pool_vm_size = "Standard_DS2_v2"
cluster_node_count        = 1
tags = {
  environment = "dev"
  repo = "pauldotyu/azure-grouper-terraform"
}