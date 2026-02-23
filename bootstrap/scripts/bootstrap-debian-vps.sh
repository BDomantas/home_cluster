#!/usr/bin/env bash
set -euo pipefail

# Phase 1 bootstrap for a fresh Debian VPS.
# Installs k3s + helm, then runs bare Argo CD + Infisical bootstrap.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BOOTSTRAP_DIR/.." && pwd)"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root (or via sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_base_packages() {
  echo "[1/6] Installing Debian packages..."
  apt-get update
  apt-get install -y ca-certificates curl git openssh-client gettext-base
}

install_k3s() {
  if command_exists k3s; then
    echo "[2/6] k3s already installed, skipping."
    return
  fi

  echo "[2/6] Installing k3s..."
  curl -sfL https://get.k3s.io | sh -
}

wait_for_k3s() {
  echo "[3/6] Waiting for k3s node to become Ready..."
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  until kubectl get nodes >/dev/null 2>&1; do
    sleep 2
  done
  kubectl wait --for=condition=Ready node --all --timeout=300s
}

install_helm() {
  if command_exists helm; then
    echo "[4/6] Helm already installed, skipping."
    return
  fi

  echo "[4/6] Installing Helm..."
  tmp_script="$(mktemp)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$tmp_script"
  chmod +x "$tmp_script"
  "$tmp_script"
  rm -f "$tmp_script"
}

prepare_kubeconfig_for_user() {
  local target_user="${SUDO_USER:-root}"
  local target_home
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  [[ -n "$target_home" ]] || target_home="/root"

  mkdir -p "$target_home/.kube"
  cp /etc/rancher/k3s/k3s.yaml "$target_home/.kube/config"
  chown -R "$target_user":"$target_user" "$target_home/.kube"

  # Replace 127.0.0.1 so kubectl works from your laptop if you copy this file later.
  if command_exists hostname; then
    server_ip="${PUBLIC_KUBE_API_IP:-$(hostname -I | awk '{print $1}')}"
    if [[ -n "${server_ip:-}" ]]; then
      sed -i "s/127.0.0.1/${server_ip}/g" "$target_home/.kube/config"
    fi
  fi
}

run_repo_bootstrap() {
  echo "[5/6] Running phase 1 (Argo CD + Infisical bootstrap) from repo..."

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  export ENABLE_ARGOCD_PORT_FORWARD=false
  "$SCRIPT_DIR/bootstrap-infisical-phase1.sh"
}

print_next_steps() {
  echo "[6/6] Bootstrap complete."
  echo
  echo "Next steps:"
  echo "  - Finish Infisical Kubernetes auth in UI (token reviewer JWT + CA + API host)"
  echo "  - Create Infisical secrets at /argocd/github-repo-creds and /argocd/ghcr-oci-creds"
  echo "  - Copy bootstrap/infisical.env.example to bootstrap/infisical.env and fill values"
  echo "  - Run check:  bash bootstrap/scripts/check-infisical-phase2.sh"
  echo "  - Run phase 2: bash bootstrap/scripts/bootstrap-infisical-phase2.sh"
  echo "  - Verify Argo CD apps: kubectl get applications -n argocd"
  echo
  echo "Infisical token reviewer JWT:"
  echo "  kubectl get secret infisical-token-reviewer-token -n infisical-system -o=jsonpath='{.data.token}' | base64 --decode && echo"
  echo "Infisical CA cert:"
  echo "  kubectl get secret infisical-token-reviewer-token -n infisical-system -o=jsonpath='{.data.ca\\.crt}' | base64 --decode && echo"
  echo "Kubernetes API host:"
  echo "  kubectl cluster-info"
}

install_base_packages
install_k3s
wait_for_k3s
install_helm
prepare_kubeconfig_for_user
run_repo_bootstrap
print_next_steps
