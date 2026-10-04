#!/usr/bin/env bash
# =====================================================================
# GitHub Actions OIDC identity: Entra app + 3 federated credentials + roles.
# No client secret is ever created.
# =====================================================================
set -euo pipefail

# ---------- EDIT THESE ----------
RG="rg-orders-demo"
AKS="aks-orders-demo"
ACR="acrthivagarorders2026"
GH_OWNER="Thivagar007"
GH_REPO="orders-api-gitops"
SUBJECT_PREFIX="repo:Thivagar007@223748060/orders-api-gitops@1403616048"
# --------------------------------

APP_ID=$(az ad app create --display-name "gh-oidc-orders-api" --query appId -o tsv)
az ad sp create --id "$APP_ID" -o none || true
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# The OIDC token's "subject" differs per job type, so we need one credential for each:
#  - build job (no environment)  -> repo:OWNER/REPO:ref:refs/heads/main
#  - deploy-dev  (environment)   -> repo:OWNER/REPO:environment:dev
#  - deploy-prod (environment)   -> repo:OWNER/REPO:environment:prod
for pair in "gh-main:ref:refs/heads/main" "gh-env-dev:environment:dev" "gh-env-prod:environment:prod"; do
  NAME="${pair%%:*}"; SUBJECT_SUFFIX="${pair#*:}"
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${NAME}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${SUBJECT_PREFIX}:${SUBJECT_SUFFIX}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
  echo "Federated credential: ${SUBJECT_PREFIX}:${SUBJECT_SUFFIX}"
done

ACR_ID=$(az acr show -n "$ACR" --query id -o tsv)
AKS_ID=$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)

# Least privilege: push images, fetch kubeconfig, read-only inside the cluster
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role AcrPush --scope "$ACR_ID" -o none
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service Cluster User Role" --scope "$AKS_ID" -o none
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
  --role "Azure Kubernetes Service RBAC Reader" --scope "$AKS_ID" -o none

echo
echo "Add these as GitHub repository VARIABLES (not secrets):"
echo "  AZURE_CLIENT_ID       = $APP_ID"
echo "  AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)"
echo "  AZURE_SUBSCRIPTION_ID = $(az account show --query id -o tsv)"
echo "  ACR_NAME              = $ACR"
echo "  AKS_RESOURCE_GROUP    = $RG"
echo "  AKS_NAME              = $AKS"
