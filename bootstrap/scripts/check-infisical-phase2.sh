#!/usr/bin/env bash
set -euo pipefail

# Validate phase 2 Infisical local metadata and rendered manifests before apply.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"
ENV_FILE="${INFISICAL_ENV_FILE:-$REPO_ROOT/bootstrap/infisical.env}"
GENERATED_DIR="${GENERATED_DIR:-$REPO_ROOT/.bootstrap-generated/infisical-check}"

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

validate_no_placeholders() {
  local file="$1"
  if rg -n '\$\{[A-Z0-9_]+\}' "$file" >/dev/null 2>&1; then
    echo "ERROR: Unresolved placeholder(s) found in $file"
    rg -n '\$\{[A-Z0-9_]+\}' "$file"
    exit 1
  fi
}

require_command envsubst
require_command kubectl
require_command rg

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: Infisical env file not found: $ENV_FILE"
  echo "Create it from: $REPO_ROOT/bootstrap/infisical.env.example"
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

mkdir -p "$GENERATED_DIR"

echo "[check] Rendering templates..."
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

for f in \
  "$GENERATED_DIR/argocd/github-repo-creds.yaml" \
  "$GENERATED_DIR/argocd/ghcr-oci-creds.yaml" \
  "$GENERATED_DIR/apps/app-config.yaml" \
  "$GENERATED_DIR/apps/netbird-mgmt-api-key.yaml"; do
  validate_no_placeholders "$f"
done

echo "[check] Client-side Kubernetes schema parse..."
if kubectl version --request-timeout=3s >/dev/null 2>&1; then
  if ! kubectl apply --dry-run=client -f "$GENERATED_DIR/argocd/github-repo-creds.yaml" >/dev/null 2>&1; then
    echo "[check] kubectl OpenAPI validation unavailable, retrying with --validate=false"
    kubectl apply --dry-run=client --validate=false -f "$GENERATED_DIR/argocd/github-repo-creds.yaml" >/dev/null
    kubectl apply --dry-run=client --validate=false -f "$GENERATED_DIR/argocd/ghcr-oci-creds.yaml" >/dev/null
    kubectl apply --dry-run=client --validate=false -f "$GENERATED_DIR/apps/app-config.yaml" >/dev/null
    kubectl apply --dry-run=client --validate=false -f "$GENERATED_DIR/apps/netbird-mgmt-api-key.yaml" >/dev/null
  else
    kubectl apply --dry-run=client -f "$GENERATED_DIR/argocd/ghcr-oci-creds.yaml" >/dev/null
    kubectl apply --dry-run=client -f "$GENERATED_DIR/apps/app-config.yaml" >/dev/null
    kubectl apply --dry-run=client -f "$GENERATED_DIR/apps/netbird-mgmt-api-key.yaml" >/dev/null
  fi
else
  echo "[check] Kubernetes API not reachable, skipping kubectl validation."
fi

echo "[check] Sanity checks..."
if ! rg -n 'argocd\.argoproj\.io/secret-type:\s*repo-creds' "$GENERATED_DIR/argocd/" >/dev/null 2>&1; then
  echo "ERROR: Argo CD repo-creds label missing in rendered argocd manifests."
  exit 1
fi

if ! rg -n "secretName:\\s*${INFISICAL_NETBIRD_SECRET_NAME}" "$GENERATED_DIR/apps/netbird-mgmt-api-key.yaml" >/dev/null 2>&1; then
  echo "ERROR: NetBird managed secret name not found in rendered NetBird manifest."
  exit 1
fi

echo
echo "Phase 2 check passed."
echo "Rendered files:"
echo "  $GENERATED_DIR/argocd/github-repo-creds.yaml"
echo "  $GENERATED_DIR/argocd/ghcr-oci-creds.yaml"
echo "  $GENERATED_DIR/apps/app-config.yaml"
echo "  $GENERATED_DIR/apps/netbird-mgmt-api-key.yaml"
echo
echo "Next step:"
echo "  bash bootstrap/scripts/bootstrap-infisical-phase2.sh"
