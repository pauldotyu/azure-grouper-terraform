provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

data "azurerm_client_config" "current" {}

# data "http" "ifconfig" {
#   url = "http://ifconfig.me"
# }

resource "random_pet" "grouper" {
  length    = 2
  separator = ""
}

resource "random_password" "grouper" {
  length           = 16
  special          = true
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  override_special = "_%@"
}

resource "azurerm_resource_group" "grouper" {
  name     = "rg-${random_pet.grouper.id}"
  location = var.location
  tags     = merge(var.tags, { "creationSource" = "terraform" })
}

################################
# AZURE MONITOR
################################

resource "azurerm_log_analytics_workspace" "grouper" {
  name                = "law-${random_pet.grouper.id}"
  resource_group_name = azurerm_resource_group.grouper.name
  location            = azurerm_resource_group.grouper.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

################################
# AZURE POSTGRESQL
################################

resource "azurerm_postgresql_server" "grouper" {
  name                         = "sql${replace(random_pet.grouper.id, "-", "")}"
  resource_group_name          = azurerm_resource_group.grouper.name
  location                     = azurerm_resource_group.grouper.location
  sku_name                     = "GP_Gen5_4"
  storage_mb                   = "5120"
  backup_retention_days        = "7"
  geo_redundant_backup_enabled = false
  auto_grow_enabled            = true
  administrator_login          = var.psql_login
  administrator_login_password = var.psql_password
  version                      = "9.6"
  ssl_enforcement_enabled      = false
}

resource "azurerm_postgresql_firewall_rule" "grouper_rule_0" {
  name                = "AllowAllWindowsAzureIps"
  resource_group_name = azurerm_resource_group.grouper.name
  server_name         = azurerm_postgresql_server.grouper.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# resource "azurerm_postgresql_firewall_rule" "grouper_rule_1" {
#   name                = "ClientIP"
#   resource_group_name = azurerm_resource_group.grouper.name
#   server_name         = azurerm_postgresql_server.grouper.name
#   start_ip_address    = data.http.ifconfig.body
#   end_ip_address      = data.http.ifconfig.body
# }

resource "azurerm_postgresql_database" "grouper" {
  name                = "grouper"
  resource_group_name = azurerm_resource_group.grouper.name
  server_name         = azurerm_postgresql_server.grouper.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}

################################
# AZURE VIRTUAL NETWORK
################################

# Create virtual network so that we can use Azure CNI network profile - this is required for the Key Vault integration
resource "azurerm_virtual_network" "grouper" {
  name                = "vn-${random_pet.grouper.id}"
  location            = azurerm_resource_group.grouper.location
  resource_group_name = azurerm_resource_group.grouper.name
  address_space       = var.vnet_address_space
  tags                = merge(var.tags, { "creationSource" = "terraform" })
}

# Create subnet
resource "azurerm_subnet" "aks" {
  name                 = "sn-${random_pet.grouper.id}-aks"
  resource_group_name  = azurerm_resource_group.grouper.name
  virtual_network_name = azurerm_virtual_network.grouper.name
  address_prefixes     = var.snet_aks_address_space
}

resource "azurerm_subnet" "ag" {
  name                 = "sn-${random_pet.grouper.id}-ag"
  resource_group_name  = azurerm_resource_group.grouper.name
  virtual_network_name = azurerm_virtual_network.grouper.name
  address_prefixes     = var.snet_agw_address_space
}

################################
# AZURE KUBERNETES SERVICE
################################

resource "azurerm_kubernetes_cluster" "grouper" {
  name                = "aks-${random_pet.grouper.id}"
  kubernetes_version  = "1.20.7" # az aks get-versions -l westus2 
  location            = azurerm_resource_group.grouper.location
  resource_group_name = azurerm_resource_group.grouper.name
  dns_prefix          = "grouper-${random_pet.grouper.id}"
  tags                = merge(var.tags, { "creationSource" = "terraform" })

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = var.default_node_pool_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin     = "azure"
    load_balancer_sku  = "Standard"
    service_cidr       = "10.255.0.0/24"
    dns_service_ip     = "10.255.0.10"
    docker_bridge_cidr = "192.168.0.1/16"
  }

  addon_profile {
    aci_connector_linux {
      enabled = false
    }

    azure_policy {
      enabled = false
    }

    http_application_routing {
      enabled = false
    }

    ingress_application_gateway {
      enabled = true
      # this does not work - when you create an ingress, nothing gets configured on the app gateway
      #gateway_id = azurerm_application_gateway.ag.id 
      # this does work
      subnet_id = azurerm_subnet.ag.id
    }

    kube_dashboard {
      enabled = false
    }

    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = azurerm_log_analytics_workspace.grouper.id
    }
  }

  role_based_access_control {
    enabled = true
    azure_active_directory {
      managed                = true
      tenant_id              = data.azurerm_client_config.current.tenant_id
      admin_group_object_ids = [var.aks_admin_group_object_id]
    }
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "grouper" {
  name                  = "internal"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.grouper.id
  vm_size               = var.cluster_node_pool_vm_size
  node_count            = var.cluster_node_count
  vnet_subnet_id        = azurerm_subnet.aks.id
  tags                  = var.tags
}

resource "azurerm_container_registry" "grouper" {
  name                = "acr${random_pet.grouper.id}"
  resource_group_name = azurerm_resource_group.grouper.name
  location            = azurerm_resource_group.grouper.location
  sku                 = "Standard"
  admin_enabled       = true
  tags                = merge(var.tags, { "creationSource" = "terraform" })
}

resource "azurerm_role_assignment" "role_acrpull" {
  scope                            = azurerm_container_registry.grouper.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.grouper.kubelet_identity.0.object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "cu_role" {
  scope                = azurerm_resource_group.grouper.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.grouper.identity.0.principal_id
}

################################
# AZURE KEY VAULT
################################

resource "azurerm_key_vault" "grouper" {
  name                            = "kv-${random_pet.grouper.id}"
  location                        = azurerm_resource_group.grouper.location
  resource_group_name             = azurerm_resource_group.grouper.name
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = true
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days      = 90
  purge_protection_enabled        = false
  sku_name                        = "standard"
  tags                            = merge(var.tags, { "creationSource" = "terraform" })
  #enable_rbac_authorization       = true
}

# Grant the current login context full access to the key vault
resource "azurerm_key_vault_access_policy" "kv_current" {
  key_vault_id = azurerm_key_vault.grouper.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  certificate_permissions = [
    "backup",
    "create",
    "delete",
    "deleteissuers",
    "get",
    "getissuers",
    "import",
    "list",
    "listissuers",
    "managecontacts",
    "manageissuers",
    "purge",
    "recover",
    "restore",
    "setissuers",
    "update"
  ]
  key_permissions = [
    "backup",
    "create",
    "decrypt",
    "delete",
    "encrypt",
    "get",
    "import",
    "list",
    "purge",
    "recover",
    "restore",
    "sign",
    "unwrapKey",
    "update",
    "verify",
    "wrapKey"
  ]
  secret_permissions = [
    "backup",
    "delete",
    "get",
    "list",
    "purge",
    "recover",
    "restore",
    "set"
  ]
  storage_permissions = [
    "backup",
    "delete",
    "deletesas",
    "get",
    "getsas",
    "list",
    "listsas",
    "purge",
    "recover",
    "regeneratekey",
    "restore",
    "set",
    "setsas",
    "update"
  ]

  depends_on = [
    azurerm_key_vault.grouper
  ]
}

# Grant AKS control node access policy on the key vault
resource "azurerm_key_vault_access_policy" "aks_system" {
  key_vault_id            = azurerm_key_vault.grouper.id
  tenant_id               = azurerm_kubernetes_cluster.grouper.identity[0].tenant_id
  object_id               = azurerm_kubernetes_cluster.grouper.identity[0].principal_id
  certificate_permissions = ["get"]
  secret_permissions      = ["get"]
  key_permissions         = ["get"]

  depends_on = [
    azurerm_key_vault_access_policy.kv_current
  ]
}

# Grant AKS worker node access policy on the key vault
resource "azurerm_key_vault_access_policy" "aks_kublet" {
  key_vault_id            = azurerm_key_vault.grouper.id
  tenant_id               = azurerm_kubernetes_cluster.grouper.identity[0].tenant_id
  object_id               = azurerm_kubernetes_cluster.grouper.kubelet_identity[0].object_id
  certificate_permissions = ["get"]
  secret_permissions      = ["get"]
  key_permissions         = ["get"]

  depends_on = [
    azurerm_key_vault_access_policy.kv_current
  ]
}

# Save secrets to Key vault
resource "azurerm_key_vault_secret" "url" {
  name         = "url"
  value        = "jdbc:postgresql://${azurerm_postgresql_server.grouper.fqdn}:5432/grouper"
  key_vault_id = azurerm_key_vault.grouper.id

  depends_on = [
    azurerm_key_vault_access_policy.kv_current
  ]
}

resource "azurerm_key_vault_secret" "username" {
  name         = "username"
  value        = format("%s@%s", var.psql_login, azurerm_postgresql_server.grouper.name)
  key_vault_id = azurerm_key_vault.grouper.id

  depends_on = [
    azurerm_key_vault_access_policy.kv_current
  ]
}

resource "azurerm_key_vault_secret" "password" {
  name         = "password"
  value        = var.psql_password_grouper_encrypted
  key_vault_id = azurerm_key_vault.grouper.id

  depends_on = [
    azurerm_key_vault_access_policy.kv_current
  ]
}

########################################################
# AZURE ROLE BASED ACCESS CONTROL FOR MANAGED IDENTITY
########################################################

# get the auto-generated resource group id
data "azurerm_resource_group" "grouper" {
  name = azurerm_kubernetes_cluster.grouper.node_resource_group
}

# Grant AKS kubelet role-based access control for the Secret Store CSI driver
resource "azurerm_role_assignment" "aks_mio" {
  scope                = data.azurerm_resource_group.grouper.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.grouper.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "aks_vmc" {
  scope                = data.azurerm_resource_group.grouper.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_kubernetes_cluster.grouper.kubelet_identity[0].object_id
}
