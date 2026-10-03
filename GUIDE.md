# Step-by-Step Guide: AKS CI/CD with Azure DevOps, GitHub Actions & Flux GitOps

This guide takes you from an empty Azure subscription to two working CI/CD pipelines
(Azure DevOps + GitHub Actions) that build, scan, push and deploy a microservice to AKS
using GitOps. Follow the steps in order. Every file mentioned is already in this repo.

---

## Step 0 — Understand what you are building (read this first)

```
 Developer pushes code to app/ on main
            │
            ▼
 ┌──────────────────────── CI/CD pipeline (Azure DevOps OR GitHub Actions) ───────────────────────┐
 │ STAGE 1  Build      : docker build → Trivy scan (fail on CRITICAL) → push image to ACR          │
 │ STAGE 2  Dev Deploy : write new tag into charts/orders-api/values-dev.yaml → git commit/push    │
 │                       → wait until the cluster is running the new tag                          │
 │ STAGE 3  Prod Deploy: ⏸ manual APPROVAL → write tag into values-prod.yaml → commit/push → wait   │
 └──────────────────────────────────────────────────────────────────────────────────────────────────┘
            │  (the pipeline never runs kubectl apply / helm upgrade)
            ▼
   GitHub repo (single source of truth)
            ▲  Flux pulls every 1 min
            │
 ┌──────── AKS cluster ────────┐
 │ flux-system : Flux controllers + HelmReleases │
 │ dev  namespace : orders-api (Deployment, Service, HPA, PDB) │
 │ prod namespace : orders-api (Deployment, Service, HPA, PDB) │
 └──────────────────────────────┘
```

**Key idea — GitOps:** the pipeline's "deploy" is just *a Git commit that changes the image tag*.
Flux (running inside AKS) watches the repo and makes the cluster match Git. If someone changes
the cluster by hand, Flux changes it back ("self-reconcile").

**Why commits don't loop:** the pipelines only trigger on changes under `app/`, and the
bot commits touch only `charts/.../values-*.yaml` and include `[skip ci]`.

### Repo layout

| Path | What it is |
|---|---|
| `app/` | Tiny Go web API (`/`, `/healthz`, `/readyz`) + multi-stage `Dockerfile` |
| `charts/orders-api/` | Helm chart: Deployment, Service, **HPA**, **PDB** |
| `charts/orders-api/values-dev.yaml`, `values-prod.yaml` | Per-environment values — pipelines update `image.tag` here |
| `deploy/flux/` | **GitOps config**: namespaces + Flux `HelmRelease` for dev and prod |
| `scripts/update-image-tag.sh` | Commits the new tag to Git (used by both pipelines) |
| `scripts/wait-for-rollout.sh` | Waits until Flux has rolled out the new tag |
| `azure-pipelines.yml` | **Azure DevOps** multi-stage pipeline |
| `.github/workflows/ci-cd.yml` | **GitHub Actions** workflow (OIDC login, no secrets) |
| `infra/01..04-*.sh` | Azure setup, OIDC identity, role grants, demo/evidence commands |

---

## Step 1 — Install the tools on your laptop

| Tool | Check | Notes |
|---|---|---|
| Azure CLI | `az version` | https://learn.microsoft.com/cli/azure/install-azure-cli |
| kubectl + kubelogin | `kubectl version --client`, `kubelogin --version` | Easiest: `az aks install-cli` (needs admin/sudo) |
| Git | `git --version` | |
| Docker (optional) | `docker version` | Only to test the image locally; Azure builds the first image for you |

Accounts you need:
- **Azure subscription** where you are *Owner* (you'll create role assignments).
- **GitHub account** (free is fine).
- **Azure DevOps organization** — create one free at https://dev.azure.com.

> ⚠️ **Azure DevOps hosted agents:** brand-new organizations often have **0 free parallel jobs**.
> Request the free grant early (it can take 1–3 business days): https://aka.ms/azpipelines-parallelism-request
> Alternative: register a self-hosted agent.

Login:
```bash
az login
az account set --subscription "<your-subscription-name-or-id>"
```

---

## Step 2 — Create the GitHub repository and push this code

1. On GitHub, click **New repository** → name `orders-api-gitops` → **Public** → *don't* add a README → Create.
   *Public* keeps it simple: Flux can read it without credentials, and environment approvals
   (required reviewers) are free on public repos.
2. Unzip this starter repo and push it:
   ```bash
   cd orders-api-gitops
   git init -b main
   git add .
   git commit -m "Initial commit: app, Helm chart, Flux, pipelines"
   git remote add origin https://github.com/<your-github-user>/orders-api-gitops.git
   git push -u origin main
   ```
3. **Don't** turn on branch protection that blocks direct pushes to `main` yet — the pipelines
   push the tag commit to `main`. (If you must protect it, allow the bot/GitHub Actions to bypass.)

> 💡 Both pipelines trigger on the same repo. While setting up, **use one pipeline at a time**
> (e.g. finish Azure DevOps first, then disable its trigger and do GitHub Actions) so they don't
> race each other for the same commit.

---

## Step 3 — Create the Azure infrastructure (RG, ACR, AKS, Flux)

1. Open `infra/01-setup-azure.sh` and edit the top variables:
   - `LOCATION` (e.g. `centralindia`)
   - `GITHUB_REPO_URL` → your repo URL from Step 2
2. Run it from the repo root:
   ```bash
   bash infra/01-setup-azure.sh
   ```
   It does, in order:
   | What | Why |
   |---|---|
   | Registers `Microsoft.ContainerService` and `Microsoft.KubernetesConfiguration` | Required for AKS and the Flux extension |
   | Creates resource group + **ACR (Basic)** | Where images are stored |
   | Creates **AKS** with Entra ID + Azure RBAC, `--attach-acr` | `--attach-acr` lets nodes pull from ACR without pull secrets |
   | Gives *you* "AKS RBAC Cluster Admin" | So your `kubectl` works |
   | `az acr build ... orders-api:initial` | Seeds an image so Flux's first install doesn't fail with ImagePullBackOff |
   | `az k8s-configuration flux create -n gitops ...` | Installs Flux and points it at `./deploy/flux` in your repo |
3. **Note the ACR name printed at the end** (e.g. `acrordersdemo12345`). Replace
   `REPLACE_ACR_NAME` in these files, then commit & push:
   - `charts/orders-api/values.yaml` → `repository: acrordersdemo12345.azurecr.io/orders-api`
   - `azure-pipelines.yml` → `acrName: 'acrordersdemo12345'`
   - `infra/02-github-oidc.sh`, `infra/03-ado-roles.sh`
   ```bash
   git commit -am "Set ACR name" && git push
   ```

> If `Standard_B2s` isn't available in your region/subscription, change `--node-vm-size`
> (e.g. `Standard_D2s_v5`). Two nodes are needed to demonstrate PDB + spreading.

---

## Step 4 — Verify GitOps (Flux) is working

```bash
az aks get-credentials -g rg-orders-demo -n aks-orders-demo --overwrite-existing
kubelogin convert-kubeconfig -l azurecli

# Flux objects
kubectl get gitrepositories,kustomizations,helmreleases -n flux-system
# Expect: gitrepository/gitops READY=True, kustomization gitops-apps READY=True,
#         helmrelease orders-api-dev / orders-api-prod READY=True

# Workloads created by Flux
kubectl get deploy,pods,svc,hpa,pdb -n dev
kubectl get deploy,pods,svc,hpa,pdb -n prod
```
Also check in the portal: **AKS → GitOps** shows the `gitops` configuration as *Compliant*.

**What just happened?** `deploy/flux/kustomization.yaml` lists namespaces and two
`HelmRelease` objects. Each HelmRelease tells Flux: "render the chart at `./charts/orders-api`
with `values.yaml` + `values-<env>.yaml` and install it into namespace `<env>`".
`reconcileStrategy: Revision` makes Flux re-render on every new commit, and
`driftDetection: enabled` makes it undo manual changes.

> Why are HelmReleases in `flux-system` and not in `dev`? The AKS Flux extension enables
> **multi-tenancy lockdown** by default, which blocks cross-namespace references. Putting the
> HelmRelease next to the GitRepository and using `targetNamespace` avoids that.

---

## Step 5 — Understand HPA and PDB in the chart

**HPA** (`charts/orders-api/templates/hpa.yaml`, `autoscaling/v2`)
- Scales on CPU 70% and memory 80% of the pod **requests** (that's why `resources.requests` are set).
- dev: 2–4 replicas, prod: 3–10 replicas.
- Scale-down waits 5 minutes (stabilization window) to avoid flapping.
- The Deployment does **not** set `replicas` when HPA is on — otherwise Git/Flux and the HPA would
  fight over the replica count. Flux drift detection also ignores `/spec/replicas`.
- AKS ships metrics-server by default, so no extra install is needed. Check: `kubectl top pods -n dev`.

**PDB** (`templates/pdb.yaml`, `policy/v1`)
- dev: `minAvailable: 1`, prod: `minAvailable: 2`.
- During node drains/upgrades, Kubernetes evicts pods only while at least that many stay available.
- Rule: `minAvailable` must be **less than** HPA `minReplicas`, or node upgrades will hang.

Other production touches already in the chart: readiness/liveness probes, non-root user,
read-only root filesystem, dropped capabilities, `maxUnavailable: 0` rolling updates,
topology spread across nodes.

---

## Step 6 — Task 1: Azure DevOps pipeline

### 6.1 Create the project
dev.azure.com → **New project** → name `orders-api` → Private → Create.

### 6.2 Create the Azure service connection (no secrets: Workload Identity Federation)
1. **Project settings → Service connections → New service connection → Azure Resource Manager**.
2. Identity type: **App registration (automatic)**, Credential: **Workload identity federation**.
3. Scope level: **Subscription** → pick your subscription → Resource group: `rg-orders-demo`.
4. Service connection name: **`sc-azure-orders`** (must match `azure-pipelines.yml`).
5. Tick **Grant access permission to all pipelines** → Save.

### 6.3 Give that identity the right Azure roles
1. Open the service connection → **Manage App registration** (or *Manage service connection roles*).
2. Go to its **Enterprise application** and copy the **Object ID**.
3. Paste it into `ADO_SP_OBJECT_ID` in `infra/03-ado-roles.sh` and run:
   ```bash
   bash infra/03-ado-roles.sh
   ```
   This grants: **AcrPush** (push images), **AKS Cluster User Role** (get kubeconfig),
   **AKS RBAC Reader** (read pods/deployments to verify the rollout).

### 6.4 Create a GitHub token so Azure DevOps can push the tag commit
1. GitHub → Settings → Developer settings → **Fine-grained personal access tokens** → Generate.
2. Repository access: *Only select repositories* → `orders-api-gitops`.
3. Permissions → Repository → **Contents: Read and write**. Generate and copy it.

### 6.5 Create the environments (this is where the approval gate lives)
1. **Pipelines → Environments → New environment** → name `orders-dev` → Resource: *None* → Create.
2. Again → `orders-prod` → Create.
3. Open `orders-prod` → **⋮ → Approvals and checks → + → Approvals** → add yourself (or a group)
   as approver → optional instructions "Verify dev before approving" → Create.

### 6.6 Create the pipeline
1. **Pipelines → New pipeline → GitHub (YAML)** → authorize the Azure Pipelines app →
   pick `orders-api-gitops`.
2. Choose **Existing Azure Pipelines YAML file** → branch `main` → path `/azure-pipelines.yml` → Continue.
3. Click **Variables → New variable** → Name `GITHUB_PAT` → paste the token →
   tick **Keep this value secret** → OK → Save.
4. Click **Run**.

### 6.7 Watch it run
- **Build** stage: docker build → Trivy report + gate → push.
  (First run may ask you to **Permit** the pipeline to use the service connection/environment —
  click *View → Permit*.)
- **Deploy to dev**: commits `chore(dev): deploy orders-api ado-<id> [skip ci]` to GitHub,
  then waits until pods in `dev` run that tag.
- **Deploy to prod**: stage shows **Waiting for approval** → click **Review → Approve**.
  Then it commits to `values-prod.yaml` and waits for the prod rollout.

### 6.8 Trigger it the "real" way
Edit `app/main.go` (e.g. change the `message` text), commit and push to `main`.
The pipeline starts automatically because `app/` changed.

---

## Step 7 — Task 2: GitHub Actions with OIDC (no stored secrets)

> First pause Azure DevOps so both don't run: in ADO → Pipeline → ⋮ → **Settings → Disabled**
> (or set `trigger: none`).

### 7.1 Create the Azure identity with federated credentials
1. Edit `GH_OWNER`, `ACR` in `infra/02-github-oidc.sh` and run:
   ```bash
   bash infra/02-github-oidc.sh
   ```
2. It creates an Entra app with **three federated credentials** — this is the #1 thing people get wrong:
   | Job | OIDC token subject |
   |---|---|
   | `build` (no environment) | `repo:<owner>/orders-api-gitops:ref:refs/heads/main` |
   | `deploy-dev` | `repo:<owner>/orders-api-gitops:environment:dev` |
   | `deploy-prod` | `repo:<owner>/orders-api-gitops:environment:prod` |
   A job that uses `environment:` gets an *environment* subject, not a branch subject.
3. It assigns AcrPush, AKS Cluster User Role and AKS RBAC Reader, and prints six values.

### 7.2 Add repository variables (NOT secrets)
GitHub repo → **Settings → Secrets and variables → Actions → Variables tab → New repository variable**:
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ACR_NAME`, `AKS_RESOURCE_GROUP`, `AKS_NAME`.
These are identifiers, not credentials — the login works through the short-lived OIDC token.

### 7.3 Create environments with an approval gate
1. **Settings → Environments → New environment** → `dev` → Configure (no rules).
2. New environment → `prod` → tick **Required reviewers** → add yourself → **Save protection rules**.

### 7.4 Allow the workflow to push
**Settings → Actions → General → Workflow permissions** → *Read and write permissions* → Save.
(The workflow also declares `contents: write` and `id-token: write`.)

### 7.5 Run it
- **Actions → orders-api CI/CD → Run workflow** (manual), or push a change under `app/`.
- `build` → `deploy-dev` run automatically; `deploy-prod` shows **Waiting** →
  **Review deployments → prod → Approve and deploy**.

---

## Step 8 — Image scanning (Trivy + optional Defender)

- Both pipelines scan the image **before pushing** it:
  - Run 1 prints every fixable HIGH/CRITICAL CVE (report only).
  - Run 2 **fails the build** if any fixable CRITICAL exists.
- To prove the gate works, temporarily change the runtime image in `app/Dockerfile` to an old one,
  e.g. `FROM debian:10`, push, and capture the red Build stage. Then revert.
- **Microsoft Defender for Containers** (optional, paid): Portal → *Microsoft Defender for Cloud →
  Environment settings → your subscription → Containers: On*. It then scans images in ACR and
  shows findings under *Recommendations → Container registry images should have vulnerability
  findings resolved*. Trivy = shift-left gate in CI; Defender = continuous scanning in the registry.

---

## Step 9 — Prove HPA, PDB and GitOps self-healing

All commands are in `infra/04-demo-evidence.sh`. Run them section by section:

1. **HPA:** start the busybox load loop in one terminal, `kubectl -n dev get hpa orders-api -w`
   in another → TARGETS rises above 70% and REPLICAS goes 2 → 3 → 4. Stop load; after ~5 min it scales down.
2. **PDB:** `kubectl -n dev get pdb` shows `ALLOWED DISRUPTIONS`. `kubectl drain <node>` evicts pods
   one at a time, never going below `minAvailable`. Then `kubectl uncordon <node>`.
3. **Self-heal:** `kubectl -n dev delete hpa orders-api` → within ~2 minutes Flux recreates it
   (`kubectl -n dev get hpa`). That's GitOps reconciliation.
4. **Git is the source of truth:** change `autoscaling.maxReplicas` in `values-dev.yaml`, push,
   and watch the HPA update without any pipeline running.

---

## Step 10 — Screenshot checklist (deliverables)

| # | Screenshot |
|---|---|
| 1 | Azure DevOps run summary showing **Build → Deploy to dev → Deploy to prod** all green |
| 2 | ADO prod stage **Waiting for approval** dialog |
| 3 | ADO Build log: Trivy scan output table |
| 4 | ADO Environments → `orders-prod` → Approvals and checks |
| 5 | GitHub Actions run graph: build → deploy-dev → deploy-prod |
| 6 | GitHub "Review deployments" approval for `prod` |
| 7 | GitHub `azure/login` step log showing OIDC login (no secrets) + Variables page |
| 8 | GitHub commit history showing the bot commits `chore(dev)/chore(prod): deploy ... [skip ci]` |
| 9 | ACR → Repositories → `orders-api` tags (`initial`, `ado-*`, `gha-*`) |
| 10 | Portal: AKS → GitOps → `gitops` *Compliant*; and `kubectl get helmreleases -n flux-system` |
| 11 | `kubectl get deploy,pods,hpa,pdb -n dev` and `-n prod` |
| 12 | HPA scaling under load (`get hpa -w`) |
| 13 | Self-heal: HPA deleted then recreated by Flux |
| 14 | (Optional) A failed build caused by the Trivy CRITICAL gate |

---

## Step 11 — Troubleshooting

| Symptom | Fix |
|---|---|
| ADO: *No hosted parallelism has been purchased or granted* | Request the free grant (Step 1) or use a self-hosted agent |
| ADO: *Pipeline does not have permission to use the service connection/environment* | Open the run → **View → Permit** |
| GitHub: `AADSTS70021: No matching federated identity record found` | Subject mismatch — check the 3 federated credentials (Step 7.1), owner/repo spelling, environment names `dev`/`prod` |
| `git push` fails with 403 in GitHub Actions | Workflow permissions → *Read and write* (Step 7.4); branch protection may be blocking |
| `git push` fails in ADO | `GITHUB_PAT` missing/expired or lacks *Contents: write* on this repo |
| Pods `ImagePullBackOff` | ACR not attached: `az aks update -g rg-orders-demo -n aks-orders-demo --attach-acr <acr>`; check repository name in `values.yaml` |
| `wait-for-rollout` times out | `kubectl describe helmrelease orders-api-dev -n flux-system`; `kubectl get gitrepository -n flux-system` (wrong repo URL/branch?) |
| `CreateContainerConfigError: image has non-numeric user` | Dockerfile must use `USER 65532:65532` (already done) |
| `kubectl`: `Forbidden` | You need *AKS RBAC Cluster Admin* (done in 01 script) and to run `kubelogin convert-kubeconfig -l azurecli` |
| HPA shows `<unknown>` targets | Wait 1–2 min for metrics; confirm `resources.requests` are set |
| Node drain hangs | PDB `minAvailable` ≥ running replicas — keep it below HPA `minReplicas` |

---

## Step 12 — Clean up (avoid charges)

```bash
az group delete -n rg-orders-demo --yes --no-wait
az ad app delete --id <AZURE_CLIENT_ID>      # GitHub OIDC app
```
Also delete the ADO service connection (it removes its app registration) and the GitHub PAT.

---

## Interview talking points

- **Why GitOps instead of `kubectl apply` from CI?** Cluster credentials stay out of CI (pipelines only
  need read access to verify), Git history is the audit log, rollback = `git revert`, drift is auto-corrected.
- **Promotion model:** same immutable image tag moves dev → prod; only the values file changes.
- **No secrets:** ADO uses Workload Identity Federation, GitHub uses OIDC federated credentials;
  the only remaining token is the GitHub PAT for ADO → GitHub pushes (could be replaced by a GitHub App).
- **Alternatives:** Flux Image Automation controllers can update tags without CI commits; ArgoCD
  would use an `Application` per environment pointing at the same chart and values files.
- **Production hardening:** separate prod cluster, private ACR/AKS with self-hosted agents,
  signed images (Notation/cosign) + admission policy, Azure Policy for AKS, SARIF upload of Trivy results.
