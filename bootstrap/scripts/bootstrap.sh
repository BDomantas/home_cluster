#!/usr/bin/env bash
set -euo pipefail

# Resolve paths relative to this script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"

ENABLE_ARGOCD_PORT_FORWARD="${ENABLE_ARGOCD_PORT_FORWARD:-true}"
APPLY_ROOT_APP="${APPLY_ROOT_APP:-true}"
RESTART_REPO_SERVER="${RESTART_REPO_SERVER:-true}"
echo
echo "[freelens] Exporting kubeconfig for Freelens..."

KUBECONFIG_OUT_DIR="${KUBECONFIG_OUT_DIR:-$HOME/.kube}"
KUBECONFIG_OUT_FILE="${KUBECONFIG_OUT_FILE:-$KUBECONFIG_OUT_DIR/freelens-kubeconfig.yaml}"

mkdir -p "$KUBECONFIG_OUT_DIR"

# Prefer k3d-dev if it exists; otherwise use current context
if kubectl config get-contexts -o name | grep -qx "k3d-dev"; then
  CTX="k3d-dev"
else
  CTX="$(kubectl config current-context)"
fi

if [[ -z "$CTX" ]]; then
  echo "ERROR: Could not determine kubectl context."
  exit 1
fi

kubectl config view \
  --minify \
  --flatten \
  --context="$CTX" \
  > "$KUBECONFIG_OUT_FILE"

chmod 600 "$KUBECONFIG_OUT_FILE"

echo "Saved kubeconfig for Freelens:"
echo "  Context: $CTX"
echo "  File:    $KUBECONFIG_OUT_FILE"

echo "[1/7] Creating argocd namespace/bootstrap manifests..."
kubectl apply -k "$BOOTSTRAP_DIR"

echo "[2/7] Installing Argo CD via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f "$BOOTSTRAP_DIR/helm-values.yaml"

echo "[3/7] Waiting for Argo CD core components..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status sts/argocd-application-controller --timeout=300s

echo "[4/7] Root app apply..."
if [[ "$APPLY_ROOT_APP" == "true" ]]; then
  if [[ -f "$REPO_ROOT/clusters/dev/root-app.yaml" ]]; then
    kubectl apply -f "$REPO_ROOT/clusters/dev/root-app.yaml"
  else
    echo "ERROR: Root app not found at $REPO_ROOT/clusters/dev/root-app.yaml"
    exit 1
  fi
else
  echo "Skipped (APPLY_ROOT_APP=$APPLY_ROOT_APP)"
fi

echo "[5/7] Repo-server restart..."
if [[ "$RESTART_REPO_SERVER" == "true" ]]; then
  kubectl -n argocd rollout restart deploy/argocd-repo-server
  kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
else
  echo "Skipped (RESTART_REPO_SERVER=$RESTART_REPO_SERVER)"
fi

echo "[6/7] Bootstrap complete."
echo "[7/7] Post-bootstrap access info..."

echo
echo "=== Argo CD admin password ==="
if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d
  echo
else
  echo "argocd-initial-admin-secret not found (maybe you disabled it or already rotated password)."
fi

echo
echo "=== Port-forward Argo CD UI ==="
echo "Open: https://localhost:8081"
if [[ "$ENABLE_ARGOCD_PORT_FORWARD" == "true" ]]; then
  echo "(CTRL+C to stop port-forward)"
  kubectl port-forward service/argocd-server -n argocd 8081:443
else
  echo "Skipped (ENABLE_ARGOCD_PORT_FORWARD=$ENABLE_ARGOCD_PORT_FORWARD)"
fi
