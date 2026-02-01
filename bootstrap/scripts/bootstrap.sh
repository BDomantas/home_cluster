#!/usr/bin/env bash
set -euo pipefail

# Resolve paths relative to this script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"

SECRETS_DIR="${SECRETS_DIR:-$HOME/.home_cluster_secrets}"
SEALED_KEY_FILE="${SEALED_KEY_FILE:-$SECRETS_DIR/sealed-secrets-master-key.yaml}"
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
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f "$BOOTSTRAP_DIR/helm-values.yaml"

echo "[3/7] Waiting for Argo CD core components..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status sts/argocd-application-controller --timeout=300s

echo "[4/7] Applying root app (installs sealed-secrets via GitOps)..."
if [[ -f "$REPO_ROOT/clusters/dev/root-app.yaml" ]]; then
  kubectl apply -f "$REPO_ROOT/clusters/dev/root-app.yaml"
else
  echo "ERROR: Root app not found at $REPO_ROOT/clusters/dev/root-app.yaml"
  exit 1
fi

echo "[5/7] Waiting for sealed-secrets controller to exist and be ready..."
until kubectl -n kube-system get deploy sealed-secrets-controller >/dev/null 2>&1; do
  echo "  - waiting for sealed-secrets-controller deployment..."
  sleep 2
done
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s

echo "[6/7] Applying Sealed Secrets master key (after controller is installed)..."
if [[ -f "$SEALED_KEY_FILE" ]]; then
  kubectl apply -f "$SEALED_KEY_FILE"
  kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
  kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=300s
else
  echo "  - WARNING: master key not found at: $SEALED_KEY_FILE"
  echo "    SealedSecrets will NOT decrypt until you restore that key."
fi

echo "[7/7] Restarting Argo CD repo-server to reload repo credentials..."
kubectl -n argocd rollout restart deploy/argocd-repo-server
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s

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
echo "(CTRL+C to stop port-forward)"
kubectl port-forward service/argocd-server -n argocd 8081:443
