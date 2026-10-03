#!/usr/bin/env bash
# Evidence commands for screenshots: HPA scale-out, PDB, GitOps self-heal.
# Run each section manually, one at a time.

# ---------- 1. What Flux is managing ----------
kubectl get gitrepositories,kustomizations,helmreleases -n flux-system
kubectl get deploy,pods,svc,hpa,pdb -n dev
kubectl get deploy,pods,svc,hpa,pdb -n prod

# ---------- 2. Call the app ----------
kubectl -n dev port-forward svc/orders-api 8080:80 &
sleep 3; curl -s localhost:8080; echo; kill %1

# ---------- 3. HPA scale-out under load (run in terminal A) ----------
kubectl -n dev run load --rm -it --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://orders-api >/dev/null; done"
# terminal B:
kubectl -n dev get hpa orders-api -w

# ---------- 4. PDB in action ----------
kubectl -n dev get pdb orders-api          # ALLOWED DISRUPTIONS column
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data   # evicts respecting PDB
kubectl uncordon "$NODE"

# ---------- 5. GitOps self-heal (drift correction) ----------
kubectl -n dev delete hpa orders-api       # manual "drift"
kubectl -n flux-system get helmrelease orders-api-dev -w   # within ~2 min Flux re-creates it
kubectl -n dev get hpa
