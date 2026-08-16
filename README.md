# cluster-flux

GitOps configuration for a homelab Kubernetes cluster. Flux CD reconciles the cluster state from this repository.

## Repository Structure

```
clusters/production/     # Flux entrypoint
infrastructure/
  controllers/           # Helm-based operators (install CRDs and run control loops)
    networking/          # metallb, gateway-api, nginx-gateway
    storage/             # democratic-csi
    security/            # cert-manager
  configs/               # Custom resources that configure the operators above
    metallb/             # IPAddressPool, L2Advertisement
    gateway/             # Gateway, HTTPRoutes, namespace
    cert-manager/        # ClusterIssuer, Certificate, Cloudflare token
apps/
  prod/                  # Production workloads (prod namespace)
  dev/                   # Development workloads (dev namespace)
talos/                   # Talos Linux OS configuration
```

## Why controllers/ and configs/ are separate

Controllers install operators via Helm — they define CRDs. Configs create instances of those CRDs to configure the operators. These must be applied in order: you cannot create an `IPAddressPool` until MetalLB's Helm chart has installed the CRD.

Flux enforces this with explicit dependencies:

```
infrastructure-controllers → infrastructure-configs → apps
```

Each is a separate Flux `Kustomization` object in `clusters/production/`. The `dependsOn` field ensures Flux will not begin applying configs until all controller HelmReleases are healthy, and will not deploy apps until configs are ready.

## Adding a new infrastructure operator

Choose the appropriate category under `infrastructure/controllers/`:

- `networking/` — anything that handles traffic routing, load balancing, or ingress
- `storage/` — storage provisioners and CSI drivers
- `security/` — PKI, certificate management, secret management

Create a directory with these files:

```
infrastructure/controllers/<category>/<name>/
  namespace.yaml     # dedicated namespace for the operator
  repo.yaml          # HelmRepository source
  release.yaml       # HelmRelease with chart version and values
  kustomization.yaml # lists the above three files as resources
```

Register it in `infrastructure/controllers/kustomization.yaml`.

If the operator needs configuration (CRD instances, pools, issuers, gateways, etc.), add a matching directory under `infrastructure/configs/<name>/` and register it in `infrastructure/configs/kustomization.yaml`. The config will be applied after all controllers are healthy.

If the config directory contains SOPS-encrypted secrets, name them `*.sops.yaml` — the `infrastructure-configs` Flux Kustomization has SOPS decryption configured. If the encrypted secret belongs in the controllers layer (e.g. a `valuesFrom` secret for a HelmRelease), it will also be decrypted as `controllers.yaml` has decryption configured too.

## Deploying a new application

Apps live under `apps/prod/` or `apps/dev/` depending on target environment. Each environment has a shared `namespace.yaml` at its root with the `gateway-access: shared` label, which permits the `shared-gateway` in the `ingress-gateway` namespace to route traffic into the namespace via `HTTPRoute` resources.

### Raw manifests

Create a directory for the app and add standard Kubernetes resources:

```
apps/prod/my-app/
  deployment.yaml
  service.yaml
  httproute.yaml     # only if the app needs external HTTP/HTTPS access
  kustomization.yaml
```

`kustomization.yaml` lists the files as resources:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
```

Register the app directory in `apps/prod/kustomization.yaml`:

```yaml
resources:
  - namespace.yaml
  - my-app
```

### Helm-based apps

Create a directory under `apps/prod/` with a HelmRepository source and HelmRelease:

```
apps/prod/my-app/
  repo.yaml          # HelmRepository
  release.yaml       # HelmRelease
  httproute.yaml     # optional, if HTTP access is needed
  kustomization.yaml
```

`repo.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 12h
  url: https://charts.example.com
```

`release.yaml`:

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: my-app
      version: "1.0.0"
      sourceRef:
        kind: HelmRepository
        name: my-app
        namespace: flux-system
      interval: 12h
  targetNamespace: prod
  values:
    # chart-specific values
```

Register in `apps/prod/kustomization.yaml` and commit.

## Networking Architecture

This cluster uses a layered networking model. Each layer has a distinct responsibility:

```
Internet / Local Network
        |
   [MetalLB]           ← assigns real IPs to LoadBalancer Services
        |
[NGINX Gateway Fabric]  ← the actual nginx proxy (runs as a pod)
        |
   [Gateway]           ← K8s object declaring "listen on port 80/443"
        |
[HTTPRoute/TCPRoute]   ← K8s objects declaring "route hostname X → service Y"
        |
  [ClusterIP Service]  ← gives a pod a stable internal DNS name
        |
      [Pod]
```

### ClusterIP

A virtual IP reachable only from inside the cluster. Used for all app services (podinfo, k8s-mcp-server) — they are internal targets that the Gateway proxies to. Do not expose these directly.

### LoadBalancer

Requests an external IP from MetalLB (pool: `10.7.0.248–10.7.0.255`). Used when a service needs a raw IP — either because it uses a non-HTTP protocol (e.g. MinIO S3 on port 9000), or to expose the Gateway Fabric itself so external traffic can enter the cluster.

### Gateway (the K8s object)

A declaration of "I want a proxy listening on these ports with this TLS config." The `shared-gateway` listens on port 80 (HTTP) and 443 (HTTPS, terminating with `wildcard-va1-uk-tls`). It is not the proxy itself — it is a config object that NGINX Gateway Fabric reads.

### NGINX Gateway Fabric

The controller that implements the Gateway API. It watches Gateway, HTTPRoute, and TCPRoute objects and translates them into live nginx configuration. NGINX is to Gateway as a driver is to a steering wheel.

### HTTPRoute / TCPRoute

Routing rules attached to a Gateway.

- **HTTPRoute**: Layer 7 — matches on hostname, path, or headers. Used for all `*.va1.uk` apps.
- **TCPRoute**: Layer 4 — forwards a raw port with no HTTP awareness. Used for MinIO because S3 clients connect by IP:port, not hostname.

### Traffic flow example

**S3 client → MinIO at `10.7.0.249:9000`**

```
1. Client connects directly to MetalLB IP:9000
2. Hits the LoadBalancer Service → pod port 9000
```

### Summary

| Concern | Solution |
|---|---|
| External access to all apps | One shared Gateway (one IP, port 443) |
| TLS termination | Gateway with wildcard cert |
| Internal service discovery | ClusterIP + DNS |
| Non-HTTP protocols (S3) | LoadBalancer Service or TCPRoute |
| IP address management | MetalLB pool (`10.7.0.248–10.7.0.255`) |

## Secrets and SOPS

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using an age key. The rules in `.sops.yaml` apply only to files matching `*.sops.yaml` and encrypt only `data` and `stringData` fields.

To create a new secret:

```bash
# Write the plain Secret yaml, then encrypt in place
sops --encrypt --in-place path/to/secret.sops.yaml
```

To edit an existing secret:

```bash
sops path/to/secret.sops.yaml
```

Never commit unencrypted secrets. The age private key must be present in the environment (`SOPS_AGE_KEY` or `~/.config/sops/age/keys.txt`) to decrypt or edit.

## Talos

Apply a SOPS-encrypted Talos config:

```bash
sops -d talos/controlplane.yaml | talosctl apply-config --nodes 10.7.2.10 --file /dev/stdin
```

See `talos/README.md` for upgrade and patch procedures.

## PVC Troubleshooting

PVCs are provisioned by democratic-csi, backed by TrueNAS iSCSI. Here are common issues and solutions:

### Common Issues

**Missing `storageClassName`**

The storage class **must** be explicitly named `iscsi`. If you omit it or use a different name, Kubernetes won't know which storage backend to use.

❌ Wrong:
```yaml
spec:
  resources:
    requests:
      storage: 5Gi
```

✅ Correct:
```yaml
spec:
  storageClassName: iscsi
  resources:
    requests:
      storage: 5Gi
```

**Using wrong `accessModes`**

Your cluster only supports `ReadWriteOnce` (single pod attachment). Using `ReadWriteMany` or `ReadOnlyMany` will cause the PVC to hang in `Pending`.

❌ Wrong:
```yaml
accessModes:
  - ReadWriteMany  # Not supported
```

✅ Correct:
```yaml
accessModes:
  - ReadWriteOnce
```

**Deployment ordering issue**

If you deploy an app before the storage controller is ready, the PVC provisioner won't be available. Verify the Flux dependency chain:

```
flux-system → infrastructure-controllers → infrastructure-configs → apps
```

Check status:
```bash
flux get all -A
```

The `democratic-csi-system` pods must be Running before apps try to create PVCs.

**TrueNAS connectivity problems**

The democratic-csi controller needs to reach TrueNAS at `tower.bigpri.me:443` and create iSCSI targets at port `3260`. Network issues, DNS resolution, or firewall rules can cause this to fail silently.

Check controller logs:
```bash
kubectl logs -n democratic-csi-system deployment/democratic-csi-controller-iscsi -f
```

**Helm chart doesn't create PVC automatically**

Some Helm charts don't include persistence by default. You may need to either:
- Enable persistence in the HelmRelease values, OR
- Create a separate `pvc.yaml` and mount it in the deployment

Example Helm approach:
```yaml
persistence:
  enabled: true
  storageClass: iscsi
  size: 10Gi
```

**Resource requests too large**

Your TrueNAS ZFS pool might not have enough free space. Check your pool's available space. If you request 100Gi but only have 50Gi free, the PVC will stay `Pending`.

### Debugging Steps

Run these commands when a PVC isn't provisioning:

```bash
# Check PVC status
kubectl describe pvc <name> -n <namespace>

# Check provisioner logs
kubectl logs -n democratic-csi-system deployment/democratic-csi-controller-iscsi -f

# Verify storage class exists
kubectl get storageclass

# Check TrueNAS connectivity from controller pod
kubectl exec -it -n democratic-csi-system deployment/democratic-csi-controller-iscsi -- bash
```

## Flux quick reference

```bash
# Check reconciliation status
flux get all -A

# Force reconcile a specific layer
flux reconcile kustomization infrastructure-controllers --with-source
flux reconcile kustomization infrastructure-configs --with-source
flux reconcile kustomization apps --with-source

# Check HelmRelease status
flux get helmrelease -A

# Check recent events for failures
flux events -A
```
