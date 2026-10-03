#!/usr/bin/env bash
# GitOps "deploy": write the new image tag into charts/orders-api/values-<env>.yaml,
# commit and push to main. Flux notices the commit and rolls it out.
#
# Usage: bash scripts/update-image-tag.sh <dev|prod> <image-tag>
# Optional env vars:
#   GITHUB_PAT + REPO_SLUG (owner/repo)  -> used by Azure DevOps to push to GitHub
#   (GitHub Actions just uses the checkout's GITHUB_TOKEN via "origin")
set -euo pipefail

ENV_NAME="${1:?env (dev|prod) required}"
TAG="${2:?image tag required}"
VALUES_FILE="charts/orders-api/values-${ENV_NAME}.yaml"

if [[ -n "${GITHUB_PAT:-}" ]]; then
  REMOTE="https://x-access-token:${GITHUB_PAT}@github.com/${REPO_SLUG:?REPO_SLUG required}.git"
else
  REMOTE="origin"
fi

if ! command -v yq >/dev/null; then
  echo "Installing yq..."
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
fi

git config user.name  "cicd-bot"
git config user.email "cicd-bot@users.noreply.github.com"

for attempt in 1 2 3 4 5; do
  # Always start from the latest main (another job may have pushed meanwhile)
  git fetch "$REMOTE" main
  git checkout -f -B main FETCH_HEAD

  yq -i ".image.tag = \"${TAG}\"" "$VALUES_FILE"

  if git diff --quiet; then
    echo "${VALUES_FILE} already at ${TAG}; nothing to commit."
    exit 0
  fi

  git add "$VALUES_FILE"
  # [skip ci] stops this commit from triggering the pipeline again
  git commit -m "chore(${ENV_NAME}): deploy orders-api ${TAG} [skip ci]"

  if git push "$REMOTE" HEAD:main; then
    echo "Pushed ${ENV_NAME} -> ${TAG}"
    exit 0
  fi
  echo "Push rejected (attempt ${attempt}); retrying..."
  sleep $((attempt * 3))
done

echo "Failed to push after 5 attempts" >&2
exit 1
