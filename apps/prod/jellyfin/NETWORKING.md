# Jellyfin Networking

Jellyfin runs with a MinIO sidecar for object storage. The two components have different networking requirements and are exposed differently.

## Jellyfin (HTTP UI)

Routed through the shared Gateway via HTTPRoute.

```
Browser → MetalLB IP:443 → NGINX Gateway Fabric → prod-jellyfin:8096 → Jellyfin pod
```

- TLS is terminated at the Gateway using `wildcard-va1-uk-tls`
- Hostname: `jellyfin.va1.uk`
- Defined in: `httproute.yaml`

## MinIO (S3 Object Storage)

Exposed directly via a dedicated LoadBalancer Service. S3 clients connect by IP:port, not by hostname, so routing through the shared Gateway is not appropriate.

```
S3 client → MetalLB IP:9000 (API) or :9001 (Console) → jellyfin-minio Service → Jellyfin pod
```

- Gets its own IP from the MetalLB pool (`10.7.0.248–10.7.0.255`)
- Port 9000: S3 API
- Port 9001: MinIO console
- Defined in: `service-minio.yaml`

## Why not TCPRoutes?

TCPRoutes through the shared Gateway were considered but rejected:

- The `shared-gateway` only has HTTP/HTTPS listeners — TCP listeners on 9000/9001 would need to be added
- It would route MinIO through the same IP as all other apps, making it harder to firewall or manage independently
- A dedicated LoadBalancer Service is simpler and keeps MinIO traffic isolated
