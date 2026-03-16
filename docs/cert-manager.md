cert-manager runbook
====================

Scope: issuance + troubleshooting for DNS-01 via Cloudflare, Gateway API TLS.

Prereqs
-------
- Cloudflare API token with Zone:Read and DNS:Edit on `va1.uk`.
- SOPS secret decrypted into cluster (`cloudflare-api-token` in `cert-manager`).

Flux/Helm actions
-----------------
- Reconcile cert-manager HelmRelease:
  ```
  k -n flux-system get helmrelease cert-manager
  k -n flux-system describe helmrelease cert-manager
  flux reconcile helmrelease cert-manager -n flux-system
  ```
- Trigger reconcile without Flux CLI:
  ```
  k -n flux-system annotate helmrelease cert-manager \
    reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite
  ```

Check cert-manager pods
-----------------------
```
k -n cert-manager get pods
k -n cert-manager describe pod <pod-name>
```

SOPS secret handling
--------------------
- Edit encrypted token:
  ```
  sops infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml
  ```
- Apply decrypted secret:
  ```
  sops -d infrastructure/configs/cert-manager/cloudflare-api-token.sops.yaml | k apply -f -
  ```
- Verify token in cluster:
  ```
  k -n cert-manager get secret cloudflare-api-token \
    -o jsonpath='{.data.api-token}' | base64 -d
  ```

Cloudflare API curl checks
--------------------------
```
export CF_API_TOKEN="your-token"
export CF_ZONE_NAME="va1.uk"
```

- Get zone (Zone:Read):
  ```
  curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=$CF_ZONE_NAME"
  ```

- Create TXT (DNS:Edit):
  ```
  export CF_ZONE_ID="zone_id_from_previous_call"
  export CF_RECORD_NAME="_acme-challenge.va1.uk"
  export CF_RECORD_VALUE="test-$(date +%s)"

  curl -sS -X POST \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    --data "{\"type\":\"TXT\",\"name\":\"$CF_RECORD_NAME\",\"content\":\"$CF_RECORD_VALUE\",\"ttl\":120}"
  ```

- List TXT (DNS:Read):
  ```
  curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=TXT&name=$CF_RECORD_NAME"
  ```

- Delete TXT (DNS:Edit):
  ```
  export CF_RECORD_ID="record_id_from_list_call"
  curl -sS -X DELETE \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID"
  ```

ACME objects
------------
- Check issuance state:
  ```
  k -n ingress-gateway get certificate
  k -n ingress-gateway get order,challenge
  k -n ingress-gateway describe order <order-name>
  k -n ingress-gateway describe challenge <challenge-name>
  ```

- Reset stuck issuance:
  ```
  k -n ingress-gateway delete challenge <challenge-name...>
  k -n ingress-gateway delete order <order-name>
  k -n ingress-gateway delete certificaterequest <request-name>
  ```

- Force re-issue:
  ```
  k -n ingress-gateway annotate certificate wildcard-va1-uk \
    cert-manager.io/renewal-reason="manual" --overwrite
  ```

Symptom: app unreachable, HTTPRoute InvalidListener (Cloudflare cleanup stuck)
------------------------------------------------------------------------------
This manifests as HTTPS traffic failing to route. The Gateway HTTPS listener becomes
invalid because the TLS secret is missing — caused by a cert-manager order stuck in
`pending` due to a Cloudflare DNS cleanup error.

Triage steps:

1. Check the HTTPRoute is accepted:
   ```
   k -n prod get httproute <route-name> -o jsonpath='{.status.parents[0].conditions}' | jq .
   ```
   Look for `Accepted: False` with reason `InvalidListener`.

2. Check the Gateway HTTPS listener:
   ```
   k -n ingress-gateway get gateway shared-gateway \
     -o jsonpath='{.status.listeners[1].conditions}' | jq .
   ```
   Look for `InvalidCertificateRef` — "secret does not exist".

3. Check the TLS secret exists:
   ```
   k -n ingress-gateway get secret wildcard-va1-uk-tls
   ```

4. Check the Certificate is Ready:
   ```
   k -n ingress-gateway get certificate wildcard-va1-uk
   ```
   If `READY: False`, check the order and challenges:
   ```
   k -n ingress-gateway get order,challenge
   ```

5. Identify the stuck challenge:
   ```
   k -n cert-manager logs -l app=cert-manager --since=10m | grep -i "error\|cloudflare"
   ```
   The tell-tale error is:
   ```
   error cleaning up challenge: while querying the Cloudflare API for
   DELETE "/zones//dns_records/<id>" Error: 7003: Could not route ...
   ```
   Note the empty zone ID (`/zones//`). This means cert-manager resolved the zone
   ID to empty during cleanup, so the DELETE request is malformed.

Root cause: cert-manager successfully completed the DNS-01 challenge (state: `valid`)
but cannot clean up the TXT record because the Cloudflare zone ID lookup returned
empty. The challenge stays `Processing: true` indefinitely, the order never finalizes,
and the TLS secret is never written.

Fix: delete the CertificateRequest to trigger a fresh order.
   ```
   k -n ingress-gateway delete certificaterequest wildcard-va1-uk-1
   ```
   cert-manager will immediately create a new CertificateRequest. Let's Encrypt
   caches valid authorizations, so only the incomplete challenges re-run. The
   secret should appear within ~60 seconds:
   ```
   k -n ingress-gateway get secret wildcard-va1-uk-tls -w
   ```

If the zone ID error recurs on the next issuance cycle, verify the Cloudflare token
has Zone:Read permission by running the curl zone lookup above.

Verify issued cert
------------------
- Inspect cert in Secret:
  ```
  k -n ingress-gateway get secret wildcard-va1-uk-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -dates
  ```

- Confirm Secret exists:
  ```
  k -n ingress-gateway get secret wildcard-va1-uk-tls
  ```
