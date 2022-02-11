terraform {
  backend "remote" {
    organization = "pauldotyu"

    workspaces {
      name = "azure-grouper" # runs locally
    }
  }
}