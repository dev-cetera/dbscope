#!/usr/bin/env bash
# Sets up keyless GitHub Actions → Firebase Hosting deploys for dbscope-prod. Usage: bash scripts/setup_firebase_deploy.sh [--yes]
#
# Creates (or reuses) a github-deploy service account with Firebase Hosting
# Admin, a Workload Identity pool + OIDC provider that only trusts
# dev-cetera/dbscope on main, and sets the GCP_WIF_PROVIDER / GCP_DEPLOY_SA
# repository variables that .github/workflows/web.yml reads. No key is created.
# Safe to run again: existing resources are reused. Without --yes it only
# prints the plan. Needs: gcloud (logged in as a project owner) and gh.
set -euo pipefail

PROJECT="dbscope-prod"
REPO="dev-cetera/dbscope"
SA_NAME="github-deploy"
POOL="github"
PROVIDER="github"
SA="$SA_NAME@$PROJECT.iam.gserviceaccount.com"

if [ "${1:-}" != "--yes" ]; then
  cat <<EOF
Would set up, in project $PROJECT:
  - enable iamcredentials, sts and firebasehosting APIs
  - service account $SA with roles/firebasehosting.admin
  - workload identity pool '$POOL' + OIDC provider '$PROVIDER' trusting only
    $REPO on refs/heads/main
  - permission for that repo to impersonate $SA
  - GitHub repo variables GCP_WIF_PROVIDER and GCP_DEPLOY_SA on $REPO
Run again with --yes to apply.
EOF
  exit 0
fi

command -v gcloud >/dev/null || { echo "gcloud is not installed" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }

NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
echo "project      $PROJECT ($NUMBER)"

gcloud services enable iamcredentials.googleapis.com sts.googleapis.com firebasehosting.googleapis.com \
  --project "$PROJECT" --quiet
echo "apis         enabled"

if ! gcloud iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" --project "$PROJECT" \
    --display-name "GitHub Actions deploy (dbscope web)" --quiet
fi
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" \
  --role roles/firebasehosting.admin --condition None --quiet >/dev/null
echo "account      $SA (firebasehosting.admin)"

if ! gcloud iam workload-identity-pools describe "$POOL" --project "$PROJECT" --location global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL" --project "$PROJECT" --location global \
    --display-name "GitHub Actions" --quiet
fi
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" --project "$PROJECT" \
     --location global --workload-identity-pool "$POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --project "$PROJECT" \
    --location global --workload-identity-pool "$POOL" \
    --display-name "GitHub OIDC" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition "assertion.repository == '$REPO' && assertion.ref == 'refs/heads/main'" \
    --quiet
fi
PROVIDER_NAME="projects/$NUMBER/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER"
echo "provider     $PROVIDER_NAME"

gcloud iam service-accounts add-iam-policy-binding "$SA" --project "$PROJECT" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$NUMBER/locations/global/workloadIdentityPools/$POOL/attribute.repository/$REPO" \
  --quiet >/dev/null
echo "binding      $REPO may impersonate $SA"

gh variable set GCP_WIF_PROVIDER --repo "$REPO" --body "$PROVIDER_NAME"
gh variable set GCP_DEPLOY_SA --repo "$REPO" --body "$SA"
echo "variables    GCP_WIF_PROVIDER, GCP_DEPLOY_SA set on $REPO"
echo
echo "Done. Trigger a deploy with: gh workflow run web.yml --repo $REPO"
