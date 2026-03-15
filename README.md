# cluster-flux

## talos

apply configuration for sops encrypted file

```
sops -d talos/controlplane.yaml | talosctl apply-config --nodes 10.7.2.10 --file /dev/stdin
```

## Deploying a New Application

Apps are organised into two directories based on environment:

- `apps/prod/` — production apps, deployed to the `prod` namespace
- `apps/dev/` — development apps, deployed to the `dev` namespace

Each environment has a shared `namespace.yaml` at its root (e.g. `apps/prod/namespace.yaml`). The `gateway-access: shared` label on these namespaces permits the `shared-gateway` (in the `ingress-gateway` namespace) to route traffic into them via `HTTPRoute` resources.

To deploy a new application, follow these steps:

1.  **Create Application Directory:**
    Create a subdirectory for your app under the appropriate environment, e.g. `apps/prod/my-new-app/`.

2.  **Define Kubernetes Manifests:**
    Create manifest files within your app directory. Each resource should reference the shared environment namespace (`prod` or `dev`). Split resources into separate files by kind:

    - `deployment.yaml`
    - `service.yaml`
    - `httproute.yaml` (if the app needs external access via the shared gateway)

    Example `apps/prod/my-new-app/deployment.yaml`:
    ```yaml
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: my-new-app
      namespace: prod
    # ...
    ```

3.  **Add a `kustomization.yaml`:**
    List your manifest files as resources:

    ```yaml
    ---
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - deployment.yaml
      - service.yaml
      - httproute.yaml
    ```

4.  **Register with the environment kustomization:**
    Add your app directory to `apps/prod/kustomization.yaml` (or `apps/dev/kustomization.yaml`):

    ```yaml
    ---
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - namespace.yaml
      - podinfo
      - my-new-app  # add your app here
    ```

    Flux watches `./apps` via `clusters/production/apps.yaml` and will pick up the change automatically.

5.  **Commit and Push:**

    ```bash
    git add .
    git commit -m "feat: add my-new-app to prod"
    git push
    ```

## Deploying a Helm-based Application

For apps distributed as Helm charts, use Flux's `HelmRepository` and `HelmRelease` resources instead of raw manifests. The structure mirrors what is used for infrastructure controllers (e.g. `cert-manager`, `metallb`).

1.  **Create the application directory** under `apps/prod/` or `apps/dev/` as appropriate.

2.  **Add a `repo.yaml`** to define the Helm chart source:

    ```yaml
    ---
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: HelmRepository
    metadata:
      name: my-new-app
      namespace: flux-system
    spec:
      interval: 12h
      url: https://charts.example.com
    ```

3.  **Add a `release.yaml`** to define the release and values:

    ```yaml
    ---
    apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    metadata:
      name: my-new-app
      namespace: flux-system
    spec:
      interval: 30m
      chart:
        spec:
          chart: my-new-app
          version: "1.0.0"
          sourceRef:
            kind: HelmRepository
            name: my-new-app
            namespace: flux-system
          interval: 12h
      targetNamespace: prod  # or dev
      values:
        # chart-specific values go here
    ```

    `install.createNamespace: true` lets Flux create the namespace automatically, so no separate `namespace.yaml` is needed.

4.  **Add a `kustomization.yaml`** referencing both files:

    ```yaml
    ---
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
      - repo.yaml
      - release.yaml
    ```

5.  **Register in `apps/kustomization.yaml`** and commit/push as normal.
