# cluster-flux

## talos

apply configuration for sops encrypted file

```
sops -d talos/controlplane.yaml | talosctl apply-config --nodes 10.7.2.10 --file /dev/stdin
```

## Deploying a New Application

To deploy a new application, follow these steps:

1.  **Create Application Directory:**
    Create a new subdirectory for your application under the `apps/` directory. For example, `apps/my-new-app/`.

2.  **Add Kustomization:**
    Inside your new application directory, create a `kustomization.yaml` file. This file will define how your application's manifests are structured and built.

    Example `apps/my-new-app/kustomization.yaml`:
    ```yaml
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization

    resources:
      - deployment.yaml
      - service.yaml
      # Add other manifest files here
    ```

3.  **Define Kubernetes Manifests:**
    Create the necessary Kubernetes manifest files within your application's directory (`apps/my-new-app/`). Define the `Namespace` inline at the top of `deployment.yaml` alongside your other resources.

    If the app needs to be reachable via the shared gateway, add the `gateway-access: shared` label to the namespace:

    ```yaml
    apiVersion: v1
    kind: Namespace
    metadata:
      name: my-new-app
      labels:
        gateway-access: shared  # required for HTTPRoute access via shared-gateway
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: my-new-app
      namespace: my-new-app
    # ...
    ```

    If the app does not need external access, omit the `gateway-access` label. There is no strict rule on namespace naming — use whatever grouping makes sense (one per app, or shared namespaces for related apps).

4.  **Register Application with Flux:**
    Add your new application directory as a resource in `apps/kustomization.yaml`:

    ```yaml
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization

    resources:
      - podinfo
      - my-new-app  # add your app here
    ```

    Flux watches `./apps` via `clusters/production/apps.yaml` and will pick up the new entry automatically.

5.  **Commit and Push:**
    Commit your changes to the Git repository and push them. Flux CD will detect the changes and apply them to the cluster.

    ```bash
    git add .
    git commit -m "feat: Add deployment for my-new-app"
    git push
    ```
