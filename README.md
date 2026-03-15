# cluster-flux

## talos

apply configuration for sops encrypted file

```
sops -d talos/controlplane.yaml | talosctl apply-config --nodes 10.7.2.10 --file /dev/stdin
```
