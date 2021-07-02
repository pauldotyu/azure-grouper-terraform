# azure-grouper

This repo is not for learning Grouper. This repo is for demonstrating how to deploy the Grouper container in Azure Kubernetes Service. This deployment my not follow best practices around secrets management so please take care to ensure you harden your deployment.

More info on Grouper can be found here: https://spaces.at.internet2.edu/display/Grouper/Grouper+container+documentation+for+v2.5

## Usage

If you want to run this manually, You will need to have the following tools installed on your machine:

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Terraform](https://www.terraform.io/downloads.html)

> These tools are available on all operating systems (i.e., Windows, MacOS, Linux)

With the tools installed, perform the following steps:

> NOTE: Many of the files in this repos have placeholder values that need to be substituted with values from your deployment. If you do a global search for "`<YOUR_`", you will see all the places that require your values.

### Azure CLI

```sh
az login
```

### Grouper encoded password

```sh
PSQL_PASSWORD=<YOUR_PSQL_PASSWORD>

# Navigate to the slashRoot/opt/grouper/grouperWebapp/WEB-INF/classes directory and run this command
PSQL_PASSWORD_ENCRYPTED=$(java -cp .:grouperClient-2.5.39.jar edu.internet2.middleware.morphString.Encrypt dontMask <<< $PSQL_PASSWORD | sed 's/Type the string to encrypt (note: pasting might echo it back): The encrypted string is: //')
```

### Terraform

Use this to provision the infrastructure you will need for this solution.

I have provided sample variable values you can use in the `sample.tfvars` files to get started. It does not include any secrets so you will need to provide the following:

- `psql_login` - This is your login for the PostgreSQL server username
- `psql_password` - This is your unencrypted PostgreSQL server password
- `psql_password_encrypted` - This is your Grouper-encrypted version of `psql_password`
- `admin_group_object_ids` - This is your Azure AD Group Object ID that will be granted "admin" privileges within the cluster

```sh
# Navigate to the terraform directory
terraform apply -var-file=sample.tfvars # you will be asked to supply few additional values

# Record the outputs as variables to be used downstream
RG_NAME=$(terraform output -raw rg_name)
AKS_NAME=$(terraform output -raw aks_name)
ACR_NAME=$(terraform output -raw acr_name)
IDENTITY_CLIENT_ID=$(terraform output -raw aks_managed_identity_client_id)
IDENTITY_RESOURCE_ID=$(terraform output -raw aks_managed_identity_resource_id)
```

### Azure Container Registry Build

Use this to build and publish your container to your Azure Container Registry.

```sh
# Navigate to the repo root directory

# Increment this as you go
GROUPER_CONTAINER_VERSION=v1

# Build and publish container using Azure Container Registry
az acr build --registry $ACR_NAME --image grouper:$GROUPER_CONTAINER_VERSION .
```

### Azure Kubernetes Service

Use this to enable additional add-ons for Azure Kubernetes Service and log into your Kubernetes cluster.

> NOTE: AS OF 6/30/21, THE SECRETS-STORE-CSI DRIVER AND PODIDENTITY ADDONS FOR AKS ARE CURRENTLY IN PREVIEW

```sh
# Navigate to the kubernetes directory

# Connect to cluster
az aks get-credentials -g $RG_NAME -n $AKS_NAME

# Register features and providers
az provider register --namespace Microsoft.ContainerService

az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnablePodIdentityPreview')].{Name:name,State:properties.state}"
az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService

az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/AKS-AzureKeyVaultSecretsProvider')].{Name:name,State:properties.state}"
az feature register --name AKS-AzureKeyVaultSecretsProvider --namespace Microsoft.ContainerService

# Install the aks-preview extension
az extension add --name aks-preview

# Update the extension to make sure you have the latest version installed
az extension update --name aks-preview

# Enable Azure Key Vault provider for Secrets Store CSI driver (CSI driver)
csi=$(az aks show -g $RG_NAME -n $AKS_NAME --query addonProfiles.azureKeyvaultSecretsProvider.enabled)
if [ -z "$csi" ] || [ "$csi" == "false" ]
then
      echo "addonProfiles.azureKeyvaultSecretsProvider being enabling now..."
      az aks enable-addons -g $RG_NAME -n $AKS_NAME -a azure-keyvault-secrets-provider
else
      echo "addonProfiles.azureKeyvaultSecretsProvider already enabled"
fi

# You can see the driver pods running with this command
kubectl get pods -n kube-system -l 'app in (secrets-store-csi-driver, secrets-store-provider-azure)'

# Enable Azure AD Pod Identity
az aks update -g $RG_NAME -n $AKS_NAME --enable-pod-identity

# Enable managed identity to be used on pods within a particular namespace
NAMESPACE=default
POD_IDENTITY_NAME=grouper-pod-identity
az aks pod-identity add -g $RG_NAME --cluster-name $AKS_NAME --namespace default --name $POD_IDENTITY_NAME --identity-resource-id $IDENTITY_RESOURCE_ID

# Verify pod identity resource exists
kubectl get azureidentity

# Test to ensure pod identity is actually working
kubectl apply -f test-pod-identity.yml
POD=$(kubectl get po -lapp=pod-identity-test -o json | jq  '.items[].metadata.name' | awk -F'"' '{ print $2}')
kubectl exec -it $POD -- az login --identity -u $IDENTITY_CLIENT_ID --allow-no-subscription -o table
kubectl delete -f test-pod-identity.yml

# Apply the secret provider class
kubectl apply -f grouper-secrets-provider.yml

# Test to ensure secrets are available within pods using pod identity and secret provider class
kubectl apply -f test-secret-provider.yml
kubectl get po

# Exec into the test pod and print all environment variables
kubectl exec -it test-secret-provider -- env
kubectl get secret # note you will see grouper-secrets for the lifetime of the pod. once you delete the pod, the secrets will go away too
kubectl delete -f test-secret-provider.yml
kubectl get secret # you should no longer see grouper-secrets

# Apply the Grouper deployments
kubectl apply -f grouper-daemon.yml
kubectl apply -f grouper-ws.yml
kubectl apply -f grouper-ui.yml
```

## Testing

```sh
kubectl get svc # note the IP address
```

Browse to https://<YOUR_PUBLIC_IP_ADDRESS>/grouper/

## Clean up

```sh
# Naviagte to the terraform directory
terraform destroy -var-file=sample.tfvars # you will be asked to supply few additional values
```
