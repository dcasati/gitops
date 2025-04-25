#!/bin/bash 

# Environment variables
export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

# AKS
export AKS_CLUSTER_NAME="aks-labs"
export RESOURCE_GROUP="rg-aks-labs"
export LOCATION="westus3"
export MANAGED_IDENTITY_NAME="akspe"

# Argo CD
export GITOPS_ADDONS_ORG="https://github.com/dcasati"
export GITOPS_ADDONS_REPO="gitops"
export GITOPS_ADDONS_BASEPATH="base/"
export GITOPS_ADDONS_PATH="bootstrap/control-plane/addons"
export GITOPS_ADDONS_REVISION="main"

# Create resource group
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

az aks create \
  --name ${AKS_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --enable-managed-identity \
  --node-count 3 \
  --generate-ssh-keys \
  --enable-oidc-issuer \
  --enable-workload-identity

az aks get-credentials \
  --name ${AKS_CLUSTER_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --file aks-labs.config

export AKS_OIDC_ISSUER_URL=$(az aks show \
  --resource-group ${RESOURCE_GROUP} \
  --name ${AKS_CLUSTER_NAME} \
  --query "oidcIssuerProfile.issuerUrl" \
  -o tsv)

az identity create \
  --name "${MANAGED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}"

export AZURE_CLIENT_ID=$(az identity show \
  --name "${MANAGED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query "clientId" -o tsv)

export PRINCIPAL_ID=$(az identity show \
  --name "${MANAGED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query "principalId" -o tsv)

az role assignment create \
  --assignee "${PRINCIPAL_ID}" \
  --role "Owner" \
  --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}"

az identity federated-credential create \
  --name "aks-labs-capz-manager-credential" \
  --identity-name "${MANAGED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${AKS_OIDC_ISSUER_URL}" \
  --subject "system:serviceaccount:azure-infrastructure-system:capz-manager" \
  --audiences "api://AzureADTokenExchange"

az identity federated-credential create \
  --name "serviceoperator" \
  --identity-name "${MANAGED_IDENTITY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${AKS_OIDC_ISSUER_URL}" \
  --subject "system:serviceaccount:azure-infrastructure-system:azureserviceoperator-default" \
  --audiences "api://AzureADTokenExchange"

## Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Create the secret manifest
cat <<EOF > aks-labs-gitops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: aks-labs-gitops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    akuity.io/argo-cd-cluster-name: ${AKS_CLUSTER_NAME}
    argo_rollouts_chart_version: 2.37.7
    argocd_chart_version: 7.6.10
    cluster_name: ${AKS_CLUSTER_NAME}
    enable_argo_events: "true"
    enable_argo_rollouts: "true"
    enable_argo_workflows: "true"
    enable_argocd: "true"
    enable_azure_crossplane_upbound_provider: "false"
    enable_cert_manager: "true"
    enable_cluster_api_operator: "false"
    enable_cluster_proportional_autoscaler: "false"
    enable_crossplane: "false"
    enable_crossplane_helm_provider: "false"
    enable_crossplane_kubernetes_provider: "false"
    enable_gatekeeper: "false"
    enable_gpu_operator: "false"
    enable_ingress_nginx: "false"
    enable_kargo: "true"
    enable_kube_prometheus_stack: "false"
    enable_kyverno: "false"
    enable_metrics_server: "false"
    enable_prometheus_adapter: "false"
    enable_secrets_store_csi_driver: "false"
    enable_vpa: "false"
    environment: control-plane
    kargo_chart_version: 0.9.1
  annotations:
    addons_repo_url: "${GITOPS_ADDONS_ORG}/${GITOPS_ADDONS_REPO}"
    addons_repo_basepath: "${GITOPS_ADDONS_BASEPATH}"
    addons_repo_path: "${GITOPS_ADDONS_PATH}"
    addons_repo_revision: "${GITOPS_ADDONS_REVISION}"
    cluster_name: ${AKS_CLUSTER_NAME}
    environment: control-plane
    infrastructure_provider: capz
    akspe_identity_id: "${AZURE_CLIENT_ID}"
    tenant_id: "${AZURE_TENANT_ID}"
    subscription_id: "${AZURE_SUBSCRIPTION_ID}"
type: Opaque
stringData:
  name: aks-labs-gitops
  server: https://kubernetes.default.svc
  config: |
    {
      "tlsClientConfig": {
        "insecure": false
      }
    }
EOF

kubectl wait --for=condition=Ready pod --all -n argocd --timeout=300s
kubectl apply -f aks-labs-gitops.yaml

cat <<EOF > bootstrap-addons.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-addons
  namespace: argocd
spec:
  syncPolicy:
    preserveResourcesOnDeletion: true
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: akuity.io/argo-cd-cluster-name
              operator: NotIn
              values: [in-cluster]
  template:
    metadata:
      name: cluster-addons
    spec:
      project: default
      source:
        repoURL: '{{metadata.annotations.addons_repo_url}}'
        path: '{{metadata.annotations.addons_repo_basepath}}{{metadata.annotations.addons_repo_path}}'
        targetRevision: '{{metadata.annotations.addons_repo_revision}}'
        directory:
          recurse: true
          exclude: exclude/*
      destination:
        namespace: 'argocd'
        name: '{{name}}'
      syncPolicy:
        automated: {}
EOF

kubectl apply -f bootstrap-addons.yaml

## CAPI needs cert-manager to be ready
kubectl wait --for=condition=Ready pod --all -n cert-manager --timeout=300s

echo "Press c to continue..."
while true; do
    read -rsn1 input  # -r: raw input, -s: silent, -n1: one character
    if [[ $input == "c" ]]; then
        break
    fi
done

### CAPI

cat <<EOF > capi-operator-values.yaml
core:
  cluster-api:
    version: v1.8.4
infrastructure:
  azure:
    version: v1.17.0
addon:
  helm:
    version: v0.2.5
manager:
  featureGates:
    core:
      ClusterTopology: true
      MachinePool: true
additionalDeployments:
  azureserviceoperator-controller-manager:
    deployment:
      containers:
        - name: manager
          args:
            --crd-pattern: "resources.azure.com/*;containerservice.azure.com/*;keyvault.azure.com/*;managedidentity.azure.com/*;eventhub.azure.com/*;storage.azure.com/*"
EOF

helm repo add capi-operator https://kubernetes-sigs.github.io/cluster-api-operator
helm repo update
helm install capi-operator capi-operator/cluster-api-operator \
  --create-namespace -n capi-operator-system \
  -f capi-operator-values.yaml

kubectl wait --for=condition=Ready pod --all -n azure-infrastructure-system --timeout=300s

cat <<EOF > identity.yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureClusterIdentity
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/sync-wave: "5"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  labels:
    clusterctl.cluster.x-k8s.io/move-hierarchy: "true"
  name: cluster-identity
  namespace: azure-infrastructure-system
spec:
  allowedNamespaces: {}
  clientID: ${AZURE_CLIENT_ID}
  tenantID: ${AZURE_TENANT_ID}
  type: WorkloadIdentity
EOF

kubectl apply -f identity.yaml

export KRO_VERSION=$(curl -sL \
    https://api.github.com/repos/kro-run/kro/releases/latest | \
    jq -r '.tag_name | ltrimstr("v")'
  )

helm install kro oci://ghcr.io/kro-run/kro/kro \
  --namespace kro \
  --create-namespace \
  --version=${KRO_VERSION}

kubectl wait --for=condition=Ready pod --all -n kro --timeout=300s

# create a resource group 
kubectl create ns mystorage


cat <<EOF > rg.yaml
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata:
  name: azurecontainer.kro.run
spec:
  schema:
    apiVersion: v1alpha1
    kind: AzureContainerDeployment
    spec:
      name: string | default=mystorage
      namespace: string | default=default
      containerName: string | default=krocontainer
      location: string | required=true
  resources:
  # These are the resources in Azure needed to run the TODO site
  - id: resourcegroup
    template:
      apiVersion: resources.azure.com/v1api20200601
      kind: ResourceGroup
      metadata:
        name: ${schema.spec.name}
        namespace: ${schema.spec.namespace}
        annotations:
          serviceoperator.azure.com/credential-from: aso-credentials
      spec:
        location: ${schema.spec.location}
  - id: storageAccount
    template:
      apiVersion: storage.azure.com/v1api20230101
      kind: StorageAccount
      metadata:
        name: ${schema.spec.name}
        namespace: ${schema.spec.namespace}
      spec:
        location: ${schema.spec.location}
        kind: StorageV2
        sku:
          name: Standard_LRS
        owner:
          name: ${resourcegroup.metadata.name}
        accessTier: Hot
  - id: blobService
    template:
      apiVersion: storage.azure.com/v1api20230101
      kind: StorageAccountsBlobService
      metadata:
        name: ${schema.spec.name}
        namespace: ${schema.spec.namespace}
      spec:
        owner:
          name: ${storageAccount.metadata.name}
  - id: container
    template:
      apiVersion: storage.azure.com/v1api20230101
      kind: StorageAccountsBlobServicesContainer
      metadata:
        name: ${schema.spec.containerName}
        namespace: ${schema.spec.namespace}
      spec:
        owner:
          name: ${blobService.metadata.name}
EOF

kubectl apply -f rg.yaml


cat <<EOF > instance.yaml
apiVersion: kro.run/v1alpha1
kind: AzureContainerDeployment
metadata:
  name: mystorage
  annotations:
    serviceoperator.azure.com/credential-from: aso-credentials 
spec:
  name: mystorage
  namespace: mystorage
  containerName: krocontainer
  location: westus2
EOF

kubectl apply -f instance.yaml
