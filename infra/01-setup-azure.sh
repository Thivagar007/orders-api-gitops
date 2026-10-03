#!/usr/bin/env bash
# =====================================================================
# One-time Azure setup: Resource group, ACR, AKS, seed image, Flux GitOps.
# Run from the repo root after `az login`. Edit the variables first.
# =====================================================================
set -euo pipefail

# ---------- EDIT THESE ----------
LOCATION="centralindia"
RG="rg-orders-demo"
AKS="aks-orders-demo"
ACR="acrordersdemo$RANDOM"           # must be globally unique, lowercase, 5-50 chars
GITHUB_REPO_URL="https://github.com/<your-github-user>/orders-api-gitops"
# --------------------------------

SUB_ID=$(az account show --query id -o tsv)
MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
echo "Subscription: $SUB_ID   ACR name will be: $ACR"

echo ">> Registering resource providers + CLI extensions"
az provider register -n Microsoft.ContainerService --wait
az provider register -n Microsoft.KubernetesConfiguration --wait
az extension add -n k8s-configuration --upgrade -y
az extension add -n k8s-extension --upgrade -y

echo ">> Resource group"
az group create -n "$RG" -l "$LOCATION" -o none

echo ">> Azure Container Registry"
az acr create -g "$RG" -n "$ACR" --sku Basic -o none

echo ">> AKS (Entra ID + Azure RBAC, OIDC issuer, ACR attached)"
az aks create -g "$RG" -n "$AKS" \
  --node-count 2 --node-vm-size Standard_B2s \
  --enable-aad --enable-azure-rbac \
  --enable-oidc-issuer --enable-workload-identity \
  --attach-acr "$ACR" \
  --generate-ssh-keys -o none

AKS_ID=$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)

echo ">> Give YOURSELF cluster-admin via Azure RBAC"
az role assignment create --assignee "$MY_OBJECT_ID" \
  --role "Azure Kubernetes Service RBAC Cluster Admin" --scope "$AKS_ID" -o none

echo ">> Seed image 'orders-api:initial' (built inside Azure, no local Docker needed)"
az acr build -r "$ACR" -t orders-api:initial app/

echo ">> Flux GitOps configuration (installs the microsoft.flux extension)"
az k8s-configuration flux create \
  -g "$RG" -c "$AKS" -t managedClusters \
  -n gitops --namespace flux-system --scope cluster \
  -u "$GITHUB_REPO_URL" --branch main --interval 1m \
  --kustomization name=apps path=./deploy/flux prune=true sync_interval=1m

echo
echo "Done. Next:"
echo "  az aks get-credentials -g $RG -n $AKS --overwrite-existing"
echo "  kubelogin convert-kubeconfig -l azurecli"
echo "  kubectl get helmreleases -n flux-system"
echo
echo "Put ACR name '$ACR' into: charts/orders-api/values.yaml, azure-pipelines.yml, GitHub variable ACR_NAME"
