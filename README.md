# orders-api-gitops

Sample microservice with end-to-end CI/CD to AKS:

- **Azure DevOps** multi-stage pipeline — `azure-pipelines.yml`
- **GitHub Actions** with OIDC Azure login — `.github/workflows/ci-cd.yml`
- **Helm chart** with HPA + PDB — `charts/orders-api/`
- **Flux GitOps** config — `deploy/flux/`
- **Trivy** image scanning in both pipelines

👉 Start with **[GUIDE.md](GUIDE.md)** — it walks through every step.
