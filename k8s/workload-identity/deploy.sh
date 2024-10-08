subscription_name="DEV"
resource_group_name="rg-k8s"
app_identity_name="id-arc-k8s"
storage_name="arck8s1000000010"
container_name="oidc"
location="westeurope"

cd k8s/workload-identity

az account set --subscription $subscription_name

az group create --name $resource_group_name --location $location

# curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64
# chmod +x ./kind
# sudo mv ./kind /usr/local/bin/kind
brew install kind
# Create identity
identity_json=$(az identity create --name $app_identity_name --resource-group $resource_group_name -o json)
client_id=$(echo $identity_json | jq -r .clientId)
principal_id=$(echo $identity_json | jq -r .principalId)
echo $client_id
echo $principal_id

subscription_id=$(az account show --query id -o tsv)

# Grant reader access to identity to subscription
az role assignment create \
 --assignee-object-id $principal_id \
 --assignee-principal-type ServicePrincipal \
 --scope /subscriptions/$subscription_id \
 --role "Reader"

# Prepare cluster
# https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters.html
openssl genrsa -out sa.key 2048
openssl rsa -in sa.key -pubout -out sa.pub

# Generate storage account
az storage account create --resource-group $resource_group_name --name $storage_name --allow-blob-public-access true
az storage container create --account-name $storage_name --name $container_name --public-access blob

cat <<EOF > openid-configuration.json
{
  "issuer": "https://${storage_name}.blob.core.windows.net/${container_name}/",
  "jwks_uri": "https://${storage_name}.blob.core.windows.net/${container_name}/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
EOF

cat openid-configuration.json

# Upload the discovery document
az storage blob upload \
   --account-name $storage_name \
  --container-name $container_name \
  --file openid-configuration.json \
  --name .well-known/openid-configuration \
  --overwrite

# Verify that the discovery document is publicly accessible
curl -s "https://${storage_name}.blob.core.windows.net/${container_name}/.well-known/openid-configuration"

# Download azwi from GitHub Releases
download=$(curl -sL https://api.github.com/repos/Azure/azure-workload-identity/releases/latest | jq -r '.assets[].browser_download_url' | grep darwin-arm64)
wget $download -O azwi.zip
tar -xf azwi.zip --exclude=*.md --exclude=LICENSE
./azwi --help
./azwi version

# Generate the JWKS document
./azwi jwks --public-keys sa.pub --output-file jwks.json
cat jwks.json

# Upload the JWKS document
az storage blob upload \
  --account-name $storage_name \
  --container-name $container_name \
  --file jwks.json \
  --name openid/v1/jwks \
  --overwrite

# Verify that the JWKS document is publicly accessible
curl -s "https://${storage_name}.blob.core.windows.net/${container_name}/openid/v1/jwks"

# Create a Kubernetes service account
service_account_oidc_issuer=$(echo "https://${storage_name}.blob.core.windows.net/${container_name}")
service_account_key_file="$(pwd)/sa.pub"
service_account_signing_file="$(pwd)/sa.key"
service_account_name="workload-identity-sa"

curl -s ${service_account_oidc_issuer}/.well-known/openid-configuration

# https://kind.sigs.k8s.io/docs/user/quick-start/
# https://hub.docker.com/r/kindest/node/tags
deploy_dir=$(pwd)

multipass mount $deploy_dir microk8s-vm:/mnt

cat microk8s-config.yaml| multipass exec -d /mnt/ microk8s-vm \
-- sudo snap set microk8s config=

microk8s inspect

cat microk8s-config.yaml| multipass exec -d /mnt/ microk8s-vm \
-- sudo cat /var/snap/microk8s/current/args/kube-apiserver|grep -e 'service-account'

docker ps || echo "Echo docker not running?"
docker ps && cat <<EOF | kind create cluster --name azure-workload-identity --image kindest/node:v1.29.2 --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    protocol: TCP
  extraMounts:
    - hostPath: ${service_account_key_file}
      containerPath: /etc/kubernetes/pki/sa.pub
    - hostPath: ${service_account_signing_file}
      containerPath: /etc/kubernetes/pki/sa.key
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        service-account-issuer: ${service_account_oidc_issuer}
        service-account-key-file: /etc/kubernetes/pki/sa.pub
        service-account-signing-key-file: /etc/kubernetes/pki/sa.key
    controllerManager:
      extraArgs:
        service-account-private-key-file: /etc/kubernetes/pki/sa.key
EOF

kubectl cluster-info --context kind-azure-workload-identity
kubectl get nodes

# Create connected cluster
az connectedk8s connect \
  --name "k8s-kind" \
  --resource-group $resource_group_name \
  --location $location 

# Install Mutating Admission Webhook
tenant_id=$(az account show --query tenantId -o tsv)
echo $tenant_id
helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts
helm repo update
helm install workload-identity-webhook azure-workload-identity/workload-identity-webhook \
  --namespace azure-workload-identity-system \
  --create-namespace \
  --set azureTenantID="${tenant_id}"

kubectl get pods -n azure-workload-identity-system
# helm uninstall workload-identity-webhook -n azure-workload-identity-system

kubectl create ns network-app

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${client_id}
    azure.workload.identity/tenant-id: ${tenant_id}
  name: ${service_account_name}
  namespace: network-app
EOF

az identity federated-credential create \
  --name "app-identity" \
  --identity-name $app_identity_name \
  --resource-group $resource_group_name \
  --issuer $service_account_oidc_issuer \
  --subject "system:serviceaccount:network-app:$service_account_name"

kubectl get serviceaccount -n network-app
kubectl describe serviceaccount -n network-app

image_tester_dir="../../../webapp-network-tester"
cd $image_tester_dir
docker build . -t jannemattila/webapp-network-tester:arm64  -f src/WebApp/Dockerfile
cd $deploy_dir
docker save jannemattila/webapp-network-tester:arm64  > webapp-network-tester_arm64_image.tar


multipass exec microk8s-vm -- ls -la
multipass exec -d /mnt/ microk8s-vm -- sudo microk8s images import < webapp-network-tester_arm64_image.tar

kubectl apply -f network-app.yaml
# kubectl delete -f network-app.yaml

kubectl get deploy -n network-app
kubectl describe deploy network-app-deployment -n network-app
kubectl get pod -n network-app
kubectl describe pod -n network-app

network_app_pod1=$(kubectl get pod -n network-app -o name | head -n 1)
echo $network_app_pod1

# https://github.com/docker/compose/issues/8600
# https://github.com/docker/for-win/issues/12018
# https://stackoverflow.com/questions/77396384/docker-desktop-running-pods-on-wsl-cannot-resolve-host-name
# https://github.com/docker/for-win/issues/13768
kubectl get deployment coredns -n kube-system -o yaml | grep image
# image: registry.k8s.io/coredns/coredns:v1.11.1 -> Not working
# kubectl patch deployment coredns -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"coredns","image":"registry.k8s.io/coredns/coredns:v1.10.0"}]}}}}'
kubectl get deployment coredns -n kube-system
kubectl get pod -n kube-system

network_app_uri="http://localhost:30000"
curl $network_app_uri
curl $network_app_uri/api/commands
curl -X POST --data "INFO ENV" "$network_app_uri/api/commands"|sort
curl -X POST --data "INFO ENV AZURE_CLIENT_ID" "$network_app_uri/api/commands"
curl -X POST --data "INFO ENV AZURE_TENANT_ID" "$network_app_uri/api/commands"
curl -X POST --data "INFO ENV AZURE_FEDERATED_TOKEN_FILE" "$network_app_uri/api/commands"
curl -X POST --data "INFO ENV AZURE_AUTHORITY_HOST" "$network_app_uri/api/commands"
curl -X POST --data "IPLOOKUP bing.com" "$network_app_uri/api/commands"
curl -X POST --data "IPLOOKUP login.microsoftonline.com" "$network_app_uri/api/commands"
curl -X POST --data "NSLOOKUP login.microsoftonline.com" "$network_app_uri/api/commands"
curl -X POST --data "TCP bing.com 443" "$network_app_uri/api/commands"
curl -X POST --data "TCP login.microsoftonline.com 443" "$network_app_uri/api/commands"
curl -X POST --data "HTTP GET \"https://login.microsoftonline.com\"" "$network_app_uri/api/commands"
curl -X POST --data "FILE READ /var/run/secrets/azure/tokens/azure-identity-token" "$network_app_uri/api/commands"

# Deploy Azure PowerShell Job

image_job_dir="../../../azure-powershell-job/src"

cd $image_job_dir
docker build . -t azure-powershell-job:mariner-2-arm64 --build-arg BUILD_VERSION=local
cd $deploy_dir

kind load docker-image azure-powershell-job:mariner-2-arm64  -n azure-workload-identity

kubectl apply -f job.yaml



kubectl get pods -n network-app
kubectl get jobs -n network-app

azure_powershell_job_pod1=$(kubectl get pod -n network-app -o name | head -n 1)
echo $azure_powershell_job_pod1

kubectl delete job azure-powershell-job -n network-app

kubectl logs $azure_powershell_job_pod1 -n network-app
kubectl exec --stdin --tty $azure_powershell_job_pod1 -n network-app -- pwsh

Get-Content $env:AZURE_FEDERATED_TOKEN_FILE -Raw

$params = @{
    ServicePrincipal = $true
    Scope = "Process"
    ApplicationId    = $env:AZURE_CLIENT_ID
    Tenant           = $env:AZURE_TENANT_ID
    FederatedToken   = Get-Content $env:AZURE_FEDERATED_TOKEN_FILE -Raw
}

Connect-AzAccount @params

Get-AzResourceGroup | Format-Table

exit

kubectl delete ns network-app

kind delete cluster --name azure-workload-identity
