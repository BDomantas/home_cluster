#!/usr/bin/env bash
set -euo pipefail

# Phase 1: bootstrap bare cluster + Argo CD + Infisical operator/bootstrap (no root app yet).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"

echo "[phase1] Installing Argo CD bootstrap without root app..."
ENABLE_ARGOCD_PORT_FORWARD=false APPLY_ROOT_APP=false RESTART_REPO_SERVER=false \
  bash "$SCRIPT_DIR/bootstrap.sh"

echo "[phase1] Installing Infisical operator (imperative, phase1 only)..."
helm repo add infisical https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/ --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install infisical-operator infisical/secrets-operator \
  -n infisical-system \
  --create-namespace \
  --version 0.10.25

echo "[phase1] Waiting for Infisical CRD registration..."
until kubectl get crd infisicalsecrets.secrets.infisical.com >/dev/null 2>&1; do
  sleep 2
done

echo "[phase1] Applying base namespaces required before root app..."
kubectl apply -f "$REPO_ROOT/clusters/base/namespaces.yaml"

echo "[phase1] Applying cluster-side Infisical Kubernetes auth bootstrap resources..."
kubectl apply -k "$REPO_ROOT/platform/infisical/bootstrap"

echo
echo "=== Infisical Kubernetes Auth (finish in UI before phase 2) ==="
echo "Token Reviewer JWT:"
echo "kubectl get secret infisical-token-reviewer-token -n infisical-system -o=jsonpath='{.data.token}' | base64 --decode && echo"
echo
echo "CA Certificate:"
echo "kubectl get secret infisical-token-reviewer-token -n infisical-system -o=jsonpath='{.data.ca\\.crt}' | base64 --decode && echo"
echo
echo "Kubernetes API host:"
echo "kubectl cluster-info"
echo
echo "After completing Infisical UI setup and creating the secret values in Infisical, run:"
echo "  bash bootstrap/scripts/bootstrap-infisical-phase2.sh"
