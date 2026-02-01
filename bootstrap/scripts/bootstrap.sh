#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$HOME/.home_cluster_secrets}"
SEALED_KEY_FILE="${SEALED_KEY_FILE:-$SECRETS_DIR/sealed-secrets-master-key.yaml}"

echo "[1/5] Creating argocd namespace (and any bootstrap manifests)..."
kubectl apply -k "${ROOT_DIR}"

echo "[2/5] Installing Argo CD via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f "${ROOT_DIR}/helm-values.yaml"

echo "[3/5] Waiting for Argo CD to be ready..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s

echo "[4/5] Applying root app (so Sealed Secrets controller gets installed via GitOps)..."
if [[ -f "${ROOT_DIR}/../clusters/dev/root-app.yaml" ]]; then
  kubectl apply -f "${ROOT_DIR}/../clusters/dev/root-app.yaml"
fi

echo "[5/5] Restoring Sealed Secrets master key"
if [[ -f "$SEALED_KEY_FILE" ]]; then
  kubectl apply -f "$SEALED_KEY_FILE"
  kubectl -n kube-system rollout restart deploy/sealed-secrets-controller || true
else
  echo "WARNING: $SEALED_KEY_FILE not found."
  echo "Your SealedSecrets will NOT decrypt until you restore the master key."
  echo "Export it once from an existing cluster and place it at: $SEALED_KEY_FILE"
fi

echo "Done."
