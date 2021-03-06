variable "email" {
  type = string
}

variable "location" {
  type = string
}

variable "vnet_address_space" {
  type        = list(string)
  description = "Virtual network address space"
}

variable "snet_aks_address_space" {
  type        = list(string)
  description = "AKS subnet address space"
}

variable "snet_agw_address_space" {
  type        = list(string)
  description = "AppGateway subnet address space"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version"
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "Default node pool VM size"
}

variable "cluster_node_pool_vm_size" {
  type        = string
  description = "Cluster node pool VM size"
}

variable "cluster_node_count" {
  type        = number
  description = "Cluster node count"
}

variable "aks_admin_group_object_id" {
  type        = string
  description = "Azure AD Admin Group Object ID for cluster admin access"
}

variable "tags" {
  type = map(any)
}

variable "psql_login" {
  type = string
}

variable "psql_password" {
  type = string
}

variable "psql_password_grouper_encrypted" {
  type = string
}

variable "grouper_system_password" {
  type = string
}

variable "custom_domain_name" {
  type = string
}