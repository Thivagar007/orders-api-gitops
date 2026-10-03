#!/usr/bin/env bash
# The pipeline does NOT kubectl apply anything (Flux does). This script just
# waits until Flux has applied the new tag and the rollout is healthy, so the
# pipeline stage goes green/red based on the real cluster state.
#
# Usage: bash scripts/wait-for-rollout.sh <namespace> <deployment> <expected-tag> [timeout-seconds]
set -euo pipefail

NS="$1"; DEPLOY="$2"; TAG="$3"; TIMEOUT="${4:-600}"
deadline=$(( $(date +%s) + TIMEOUT ))

echo "Waiting for Flux to roll ${DEPLOY} in namespace ${NS} to tag ${TAG}..."
while true; do
  current=$(kubectl get deployment "$DEPLOY" -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [[ "$current" == *":${TAG}" ]]; then
    echo "Flux applied the new image: ${current}"
    break
  fi
  if (( $(date +%s) > deadline )); then
    echo "Timed out. Current image: ${current:-<none>}" >&2
    kubectl get helmreleases -n flux-system 2>/dev/null || true
    exit 1
  fi
  echo "  current image: ${current:-<not found>} ... checking again in 15s"
  sleep 15
done

kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=300s
echo "---- Resources in ${NS} ----"
kubectl get deploy,pods,hpa,pdb -n "$NS" -l app.kubernetes.io/name=orders-api -o wide
