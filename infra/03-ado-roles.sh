#!/usr/bin/env bash
# =====================================================================
# Grant the Azure DevOps service connection's identity the roles it needs.
# Find its Object ID: Project settings > Service connections > sc-azure-orders
#   > "Manage App registration" / "Manage service connection roles"
#   > Enterprise application > Object ID
# =====================================================================
set -euo pipefail

RG="rg-orders-demo"
AKS="aks-orders-demo"
ACR="REPLACE_ACR_NAME"
ADO_SP_OBJECT_ID="<object-id-of-the-service-connection-service-principal>"

ACR_ID=$(az acr show -n "$ACR" --query id -o tsv)
AKS_ID=$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)

for role in "AcrPush:$ACR_ID" \
            "Azure Kubernetes Service Cluster User Role:$AKS_ID" \
            "Azure Kubernetes Service RBAC Reader:$AKS_ID"; do
  ROLE="${role%%:*}"; SCOPE="${role#*:}"
  az role assignment create --assignee-object-id "$ADO_SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal --role "$ROLE" --scope "$SCOPE" -o none
  echo "Assigned: $ROLE"
done
