#!/usr/bin/env bash
set -euo pipefail

# Phase 2: apply Infisical-backed Argo CD repo credentials, then start GitOps root app.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"
ENV_FILE="${INFISICAL_ENV_FILE:-$REPO_ROOT/bootstrap/infisical.env}"
GENERATED_DIR="${GENERATED_DIR:-$REPO_ROOT/.bootstrap-generated/infisical}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1"
    exit 1
  }
}

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: Required variable '$name' is empty or unset."
    exit 1
  fi
}

render_template() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  envsubst < "$src" > "$dst"
}

require_command kubectl
require_command envsubst

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Infisical env file not found: $ENV_FILE"
  echo "Copy $REPO_ROOT/bootstrap/infisical.env.example to bootstrap/infisical.env and fill values."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for v in \
  INFISICAL_IDENTITY_ID \
  INFISICAL_PROJECT_SLUG \
  INFISICAL_ENV_SLUG \
  INFISICAL_HOST_API \
  INFISICAL_ARGOCD_GITHUB_REPO_CREDS_PATH \
  INFISICAL_ARGOCD_GHCR_OCI_CREDS_PATH \
  INFISICAL_APP_CONFIG_NAMESPACE \
  INFISICAL_APP_CONFIG_SECRET_NAME \
  INFISICAL_APP_CONFIG_PATH \
  INFISICAL_NETBIRD_SECRET_NAMESPACE \
  INFISICAL_NETBIRD_SECRET_NAME \
  INFISICAL_NETBIRD_OPERATOR_API_KEY_PATH; do
  require_var "$v"
done

echo "[phase2] Rendering InfisicalSecret manifests from templates..."
render_template \
  "$REPO_ROOT/platform/infisical/templates/argocd/github-repo-creds.yaml.tmpl" \
  "$GENERATED_DIR/argocd/github-repo-creds.yaml"
render_template \
  "$REPO_ROOT/platform/infisical/templates/argocd/ghcr-oci-creds.yaml.tmpl" \
  "$GENERATED_DIR/argocd/ghcr-oci-creds.yaml"
render_template \
  "$REPO_ROOT/platform/infisical/templates/apps/app-config.yaml.tmpl" \
  "$GENERATED_DIR/apps/app-config.yaml"
render_template \
  "$REPO_ROOT/platform/infisical/templates/apps/netbird-mgmt-api-key.yaml.tmpl" \
  "$GENERATED_DIR/apps/netbird-mgmt-api-key.yaml"

echo "[phase2] Applying InfisicalSecret CRs for Argo CD repo credentials..."
kubectl apply -f "$GENERATED_DIR/argocd/github-repo-creds.yaml"
kubectl apply -f "$GENERATED_DIR/argocd/ghcr-oci-creds.yaml"

echo "[phase2] Applying app InfisicalSecret CR(s)..."
kubectl apply -f "$GENERATED_DIR/apps/app-config.yaml"
kubectl apply -f "$GENERATED_DIR/apps/netbird-mgmt-api-key.yaml"

echo "[phase2] Waiting for Argo CD GitHub repo credentials secret..."
until kubectl -n argocd get secret github-repo-creds >/dev/null 2>&1; do
  sleep 2
done

echo "[phase2] Waiting for Argo CD GHCR OCI repo credentials secret..."
until kubectl -n argocd get secret ghcr-oci-creds >/dev/null 2>&1; do
  sleep 2
done

echo "[phase2] Waiting for NetBird operator API key secret..."
until kubectl -n "$INFISICAL_NETBIRD_SECRET_NAMESPACE" get secret "$INFISICAL_NETBIRD_SECRET_NAME" >/dev/null 2>&1; do
  sleep 2
done

echo "[phase2] Restarting Argo CD repo-server to reload repo credentials..."
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s

echo "[phase2] Applying root app (GitOps takes over)..."
kubectl apply -f "$REPO_ROOT/clusters/dev/root-app.yaml"

echo
echo "Phase 2 complete."
echo "Check Argo apps:"
echo "  kubectl get applications -n argocd"
echo "Check NetBird API key secret:"
echo "  kubectl get secret -n $INFISICAL_NETBIRD_SECRET_NAMESPACE $INFISICAL_NETBIRD_SECRET_NAME"
