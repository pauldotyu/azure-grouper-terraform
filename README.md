# azure-grouper-terraform

This repo is not for learning Grouper. This repo is for demonstrating how to deploy the Grouper container in Azure Kubernetes Service using Terraform. This deployment my not follow best practices around secrets management so please take care to ensure you harden your deployment.

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

### Make sure you are running a supported version of Kubernetes

```sh
az aks get-versions --location westus2 --output table
```

### Grouper encoded password

```sh
PSQL_PASSWORD=<YOUR_PSQL_PASSWORD>

# Navigate to the slashRoot/opt/grouper/grouperWebapp/WEB-INF/classes directory and run this command
PSQL_PASSWORD_GROUPER_ENCRYPTED=$(java -cp .:grouperClient-2.5.39.jar edu.internet2.middleware.morphString.Encrypt dontMask <<< $PSQL_PASSWORD | sed 's/Type the string to encrypt (note: pasting might echo it back): The encrypted string is: //')
```

### Terraform

Use this to provision the infrastructure you will need for this solution.

Initialize your backend by adding a file called backend.hcl. My project is connected to Terraform Cloud as the remote state provider and the contents look like this:

```hcl
workspaces { name = "azure-virtual-desktop-ops-terraform" }
hostname     = "app.terraform.io"
organization = "contosouniversity"
```

Now initialize by running this command:

```sh
terraform init -backend-config=backend.hcl
```

I have provided sample variable values you can use in the `sample.tfvars` files to get started. It does not include any secrets so you will need to provide the following:

- `psql_login` - This is your login for the PostgreSQL server username
- `psql_password` - This is your unencrypted PostgreSQL server password
- `psql_password_grouper_encrypted` - This is your Grouper-encrypted version of `psql_password`
- `aks_admin_group_object_id` - This is your Azure AD Group Object ID that will be granted "admin" privileges within the cluster

```sh
# Navigate to the terraform directory
terraform apply -var-file=sample.tfvars # you will be asked to supply few additional values

# Record the outputs as variables to be used downstream
RG_NAME=$(terraform output -raw rg_name)
AKS_NAME=$(terraform output -raw aks_name)
ACR_NAME=$(terraform output -raw acr_login_server)
IDENTITY_RESOURCE_ID=$(terraform output -raw aks_managed_identity_resource_id)
AKV_NAME=$(terraform output -raw akv_name)
```

### Azure Container Registry Build

Use this to build and publish your container to your Azure Container Registry.

```sh
# Navigate to the repo root directory

# Increment this as you go
GROUPER_CONTAINER_VERSION=v1

# Build and publish container using Azure Container Registry
az acr build -t grouper:latest -r $ACR_NAME ../docker

```

### Azure Kubernetes Service

Use this to enable additional add-ons for Azure Kubernetes Service and log into your Kubernetes cluster.

```sh
# Navigate to the kubernetes directory

# Connect to cluster
az aks get-credentials -g $RG_NAME -n $AKS_NAME

# Register features and providers
az provider register --namespace Microsoft.ContainerService

az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnablePodIdentityPreview')].{Name:name,State:properties.state}"
az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService

# Install the aks-preview extension
az extension add --name aks-preview

# Update the extension to make sure you have the latest version installed
az extension update --name aks-preview

# You can see the secrets-store-* pods running with this command
kubectl get pods -n kube-system -l 'app in (secrets-store-csi-driver, secrets-store-provider-azure)'
```

[Azure AD Pod Identity](https://github.com/Azure/aad-pod-identity) will be replaced with [Azure Workload Identity](https://github.com/Azure/azure-workload-identity) which relies on an [OIDC issuer](https://docs.microsoft.com/en-us/azure/aks/cluster-configuration#oidc-issuer-preview) to be configured in your cluster.

Follow this [doc](https://azure.github.io/azure-workload-identity/docs/installation.html) to install AADWI and use it against Azure Key Vault.

> https://azure.github.io/azure-workload-identity/docs/introduction.html

```sh
# Enable OIDC issuer URLs on the cluster
az feature register --name EnableOIDCIssuerPreview --namespace Microsoft.ContainerService

# Check the feature registration status
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableOIDCIssuerPreview')].{Name:name,State:properties.state}"

# Enable OIDC issuer on the cluster
az aks update -g $RG_NAME -n $AKS_NAME --enable-oidc-issuer

# Show the OIDC issuer URL
export SERVICE_ACCOUNT_ISSUER="$(az aks show -g $RG_NAME -n $AKS_NAME --query "oidcIssuerProfile.issuerUrl" -otsv)"

# Get the tenant id
export AZURE_TENANT_ID="$(az account show --query tenantId -otsv)"

# Install Azure Workload Identity using Helm3
helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts
helm repo update
helm install workload-identity-webhook azure-workload-identity/workload-identity-webhook \
   --namespace azure-workload-identity-system \
   --create-namespace \
   --set azureTenantID="${AZURE_TENANT_ID}"

# Install envsubst
curl -sL https://github.com/Azure/azure-workload-identity/releases/download/v0.10.0/azure-wi-webhook.yaml | envsubst | kubectl apply -f -

# Install Linuxbrew (if running from linux)
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Linuxbrew/install/master/install.sh)"
echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> /home/paul/.zprofile
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# Install azwi
brew install Azure/azure-workload-identity/azwi

# Create an Azure AD application
export APPLICATION_NAME="grouper-wi"
azwi serviceaccount create phase app --aad-application-name "${APPLICATION_NAME}"

# Create a service principal from the Azure AD application
export APPLICATION_CLIENT_ID=$(az ad sp create-for-rbac --name "${APPLICATION_NAME}" --query appId -otsv)

# Grant the service principal an access policy on the key vault
az keyvault set-policy --name $AKV_NAME \
  --secret-permissions get \
  --spn "${APPLICATION_CLIENT_ID}"

# Create a kubernetes service account
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="grouper"
azwi serviceaccount create phase sa \
  --aad-application-name "${APPLICATION_NAME}" \
  --service-account-namespace "${SERVICE_ACCOUNT_NAMESPACE}" \
  --service-account-name "${SERVICE_ACCOUNT_NAME}"

# Annotate the service account
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${APPLICATION_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
EOF

# Establish federated identity credential between the Azure AD application and the service account issuer and subject
azwi serviceaccount create phase federated-identity \
  --aad-application-name "${APPLICATION_NAME}" \
  --service-account-namespace "${SERVICE_ACCOUNT_NAMESPACE}" \
  --service-account-name "${SERVICE_ACCOUNT_NAME}" \
  --service-account-issuer-url "${SERVICE_ACCOUNT_ISSUER}"

# Get the object ID of the AAD application
export APPLICATION_OBJECT_ID="$(az ad app show --id ${APPLICATION_CLIENT_ID} --query objectId -otsv)"

# Add the federated identity credential
cat <<EOF > body.json
{
  "name": "kubernetes-federated-credential",
  "issuer": "${SERVICE_ACCOUNT_ISSUER}",
  "subject": "system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}",
  "description": "Kubernetes service account federated credential",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF

az rest --method POST --uri "https://graph.microsoft.com/beta/applications/${APPLICATION_OBJECT_ID}/federatedIdentityCredentials" --body @body.json

# Run a pod to ensure workload identity is actually working
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: quick-start
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
    - image: ghcr.io/azure/azure-workload-identity/msal-go
      name: oidc
      env:
      - name: KEYVAULT_NAME
        value: $AKV_NAME
      - name: SECRET_NAME
        value: "url"
  nodeSelector:
    kubernetes.io/os: linux
EOF

# Test the pod then delete
kubectl describe pod quick-start
kubectl logs quick-start
kubectl delete pod quick-start

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
