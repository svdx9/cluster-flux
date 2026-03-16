# Jellyfin Networking

Jellyfin runs with a MinIO sidecar for object storage. Each component is exposed separately through the shared Gateway.

## Jellyfin (HTTP UI)

```
Browser → MetalLB IP:443 → NGINX Gateway Fabric → prod-jellyfin:8096 → Jellyfin pod
```

- Hostname: `jellyfin.va1.uk`
- TLS terminated at the Gateway using `wildcard-va1-uk-tls`
- Defined in: `httproute.yaml`

## MinIO Console (HTTP UI)

```
Browser → MetalLB IP:443 → NGINX Gateway Fabric → jellyfin-minio:9001 → Jellyfin pod
```

- Hostname: `jellyfin-minio.va1.uk`
- TLS terminated at the Gateway using `wildcard-va1-uk-tls`
- Defined in: `httproute-minio.yaml`

## MinIO S3 API (port 9000)

The S3 API is only accessible internally (ClusterIP). If external S3 access is needed, either add an HTTPRoute for port 9000 or change `service-minio.yaml` back to LoadBalancer.

## Services

`service-minio.yaml` defines a ClusterIP Service selecting the Jellyfin pod on ports 9000 and 9001. Both components route through the shared Gateway — no dedicated external IP is needed.

## Why not TCPRoutes?

TCPRoutes were considered for MinIO but rejected. Both the S3 API and console speak HTTP, so HTTPRoutes handle them correctly with full TLS termination at the Gateway.
