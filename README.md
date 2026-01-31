# Local Development

## Prerequisites
- Docker
- [k3d](https://k3d.io/) (`curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helmfile](https://helmfile.readthedocs.io/en/latest/#installation) (Download binary from [Releases](https://github.com/helmfile/helmfile/releases))

## Bootstrap Cluster

### 1. Create the Cluster
Run the helper script to create a k3d cluster named `dev`:
```bash
./scripts/k3d-create.sh
```
*Note: This disables the default Traefik ingress controller to allow custom configurations.*

### 2. Apply Cluster Resources
Create namespaces and core configurations:
```bash
kubectl apply -k cluster/overlays/dev
```

### 3. Deploy Platform Services
We use **Helmfile** to manage releases across environments. This ensures that Dev and Prod are identical in structure.

```bash
# Sync the Dev environment
helmfile -e dev sync

# Sync the Prod environment
# helmfile -e prod sync
```

### 4. Verify
Check that all pods are running:
```bash
kubectl get pods -A
```
