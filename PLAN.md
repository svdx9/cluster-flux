# Jellyfin Deployment Plan with Persistent Storage
## Overview
Deploy Jellyfin media server to the production cluster with persistent storage backed by TrueNAS via iSCSI.
## Prerequisites
- TrueNAS at `tower.bigpri.me` with iSCSI target configured
- API key with appropriate permissions on TrueNAS
- Domain for external access (e.g., `jellyfin.yourdomain.com`)
- SOPS configured for secrets encryption
---
## Phase 1: Deploy Storage Infrastructure
### 1.1 Create democratic-csi namespace
**File:** `infrastructure/controllers/democratic-csi/namespace.yaml`
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: democratic-csi-system
  labels:
    app.kubernetes.io/managed-by: flux
1.2 Add HelmRepository
File: infrastructure/controllers/democratic-csi/repo.yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: democratic-csi
  namespace: flux-system
spec:
  interval: 12h
  url: https://democratic-csi.github.io/charts/
1.3 Create HelmRelease with TrueNAS configuration
File: infrastructure/controllers/democratic-csi/release.yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: democratic-csi
  namespace: flux-system
spec:
  interval: 30m
  chart:
    spec:
      chart: democratic-csi
      version: "0.3.0"
      sourceRef:
        kind: HelmRepository
        name: democratic-csi
        namespace: flux-system
  targetNamespace: democratic-csi-system
  install:
    createNamespace: true
  values:
    csiDriver:
      name: "iscsi"
    driver:
      config:
        driver: freenas-api-iscsi
        instance_id: "iscsi-cluster"
        httpConnection:
          protocol: https
          host: tower.bigpri.me
          port: 443
          apiKey: "<SOPS_ENC_KEY>"
          allowInsecure: false
        zfs:
          datasetParentName: storage/k8s-ds/v
          detachedSnapshotsDatasetParentName: storage/k8s-ds/s
        iscsi:
          targetPortal: "tower.bigpri.me:3260"
          targetGroups:
            - targetGroupPortalGroup: 1
              targetGroupInitiatorGroup: 2
              targetGroupAuthType: None
    storageClasses:
      - name: iscsi
        defaultClass: false
        reclaimPolicy: Delete
        volumeBindingMode: Immediate
        allowVolumeExpansion: true
        parameters:
          fsType: ext4
1.4 Create kustomization
File: infrastructure/controllers/democratic-csi/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - repo.yaml
  - release.yaml
1.5 Update infrastructure kustomization
File: infrastructure/kustomization.yaml
resources:
  - controllers/metallb
  - controllers/cert-manager
  - controllers/gateway-api
  - controllers/nginx-gateway
  - controllers/democratic-csi  # add this
---
Phase 2: Deploy Jellyfin
2.1 Create PersistentVolumeClaim
File: apps/prod/jellyfin/pvc.yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-data
  namespace: prod
spec:
  storageClassName: iscsi
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
2.2 Create Deployment with PVC mount
File: apps/prod/jellyfin/deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jellyfin
  namespace: prod
  labels:
    app: jellyfin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jellyfin
  template:
    metadata:
      labels:
        app: jellyfin
    spec:
      containers:
        - name: jellyfin
          image: jellyfin/jellyfin:10.9
          ports:
            - name: http
              containerPort: 8096
          volumeMounts:
            - name: config
              mountPath: /config
            - name: media
              mountPath: /media
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
            limits:
              cpu: 2
              memory: 4Gi
          env:
            - name: TZ
              value: "America/New_York"
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: jellyfin-data
        - name: media
          persistentVolumeClaim:
            claimName: jellyfin-data
2.3 Create Service
File: apps/prod/jellyfin/service.yaml
---
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: prod
spec:
  selector:
    app: jellyfin
  ports:
    - name: http
      port: 8096
      targetPort: 8096
2.4 Create HTTPRoute for external access
File: apps/prod/jellyfin/httproute.yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: jellyfin
  namespace: prod
  labels:
    app: jellyfin
spec:
  parentRefs:
    - name: shared-gateway
      namespace: ingress-gateway
  hostnames:
    - "jellyfin.example.com"  # TODO: replace with actual domain
  rules:
    - backendRefs:
        - name: jellyfin
          port: 8096
2.5 Create kustomization
File: apps/prod/jellyfin/kustomization.yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - httproute.yaml
2.6 Update prod apps kustomization
File: apps/prod/kustomization.yaml
resources:
  - namespace.yaml
  - podinfo
  - k8s-mcp-server
  - jellyfin  # add this
---
Phase 3: Deploy
git add .
git commit -m "feat: add democratic-csi storage and jellyfin media server"
git push
Flux will automatically reconcile:
1. Deploy democratic-csi → creates iscsi StorageClass
2. PVC binds to PV via StorageClass
3. Jellyfin Deploy → mounts PVC
4. HTTPRoute → enables external access
---
Post-Deployment Tasks
- [ ] Update DNS to point jellyfin.example.com to your gateway IP
- [ ] Configure Jellyfin through web UI on first login
- [ ] Add media library paths (/config, /media)
- [ ] (Optional) Enable transcoding if hardware acceleration available
---
Rollback Plan
If issues occur:
# Remove jellyfin app
kubectl delete -n prod部署 jellyfin,jellyfin-data
# Or revert git commit and push
For storage issues, delete the HelmRelease:
flux delete hr democratic-csi -n flux-system
