#!/usr/bin/env bash
set -e

echo "[1/2] Creating argocd namespace..."
kubectl apply -k ../

echo "[2/2] Installing Argo CD via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  -f ../helm-values.yaml
