# ESO vs VSO lab

A side-by-side comparison of the **External Secrets Operator** and the **Vault Secrets Operator** against one Vault Enterprise instance, on a local kind cluster running on Podman.

```
┌──────────────────────── kind cluster (Podman) ────────────────────────┐
│                                                                        │
│  vault/        Vault Enterprise (Raft, 1 node) ── namespace demo        │
│                  kv/  database/  pki/  vso-transit/  auth/kubernetes   │
│  db/           Postgres 16                                             │
│                                                                        │
│  vault-secrets-operator-system/  VSO 1.6        external-secrets/  ESO │
│        │                                                   │           │
│  app-vso/  app ◄─ app-config, db-creds, app-tls     app-eso/  app ◄─ … │
│                                                                        │
│  demo-ui/  dashboard  (compares each Secret with what each app uses)   │
└────────────────────────────────────────────────────────────────────────┘
      localhost:8200 → Vault                localhost:8080 → dashboard
```

## Prerequisites

- Podman with a **rootful** machine of at least 4 CPUs and 8 GB:
  ```bash
  podman machine init --rootful --cpus 4 --memory 8192   # or, for an existing machine:
  podman machine stop && podman machine set --rootful --cpus 4 --memory 8192 && podman machine start
  ```
- `brew install kind kubectl helm terraform jq`
- A Vault Enterprise licence at `license/vault.hclic`

## Run it

```bash
./scripts/up.sh        # about 5–8 minutes the first time (image pulls)
```

Then open http://localhost:8080 and follow **RUNSHEET.md**.

| | |
|---|---|
| Dashboard | http://localhost:8080 |
| Vault UI | http://localhost:8200/ui (namespace `demo`) |
| Root token | `jq -r .root_token .secrets/vault-init.json` |
| Health check | `./scripts/status.sh` |
| After the Mac sleeps | `podman machine start && ./scripts/unseal.sh` |
| Tear down | `./scripts/down.sh` |

## Settings

Copy `lab.env.example` to `lab.env` to override defaults: Vault Enterprise image tag, chart versions, cluster name. **Pin `ESO_CHART_VERSION` once you've rehearsed**, so the demo doesn't change under you.

## Layout

| Path | What |
|---|---|
| `scripts/` | `up.sh` runs preflight and stages 00–50 in order; each stage can be re-run on its own |
| `terraform/` | All Vault config: namespace, engines, auth roles, policies |
| `k8s/app-vso/` | VaultConnection, VaultAuth, VaultStaticSecret, VaultDynamicSecret, VaultPKISecret, app |
| `k8s/app-eso/` | SecretStore, two VaultDynamicSecret generators, three ExternalSecrets, app |
| `k8s/platform/` | Postgres, dashboard |
| `app/app.py` | Demo app and dashboard. Standard library only, mounted from a ConfigMap, so there's no image to build |
| `demo/` | One script per scenario |

## Design choices worth knowing

- **Fairness is the point.** Both sides use the same Vault namespace, the same auth method and the same service account name, and their policies are near-identical. ESO refresh intervals are set sensibly (see the comments in `k8s/app-eso/20-externalsecrets.yaml`). If the client's engineers check the config, it has to hold up.
- **The app reads secrets once at start-up** (env vars and a certificate file), like most real applications. That's what makes the "app on old value" state visible. Change it to read mounted files live and the reload gap narrows. Be ready to say so if asked.
- **Air-gap.** The images are `hashicorp/vault-enterprise`, `postgres:16-alpine`, `python:3.12-alpine` and the two operator charts' images. Mirror those and the Helm charts, and the lab runs with no internet.

## What this lab is not

It's a demo, not a reference architecture. Vault runs over plain HTTP, has one unseal key, and Terraform and the scripts use the root token. Postgres storage is ephemeral. Don't copy these settings into a client environment.
