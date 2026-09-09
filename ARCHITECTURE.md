# Architecture — Cluster K3s SoluDev + VPS Storage

Dernière mise à jour : 7 septembre 2026

## Vue d'ensemble

```
                        ┌─────────────────────────────────────────┐
                        │           INTERNET (utilisateurs)      │
                        └──────────────────┬──────────────────────┘
                                           │
                                Cloudflare (DNS, tunnel)
                                           │ cloudflared ×2 (k8s)
                    ┌──────────────────────┴─────────────────────┐
                    │      CLUSTER K3S — apps & services        │
                    │  1 control-plane + 4 workers (Tailscale) │
                    └──┬──────────────────────────────────┬─────┘
                       │ Tailscale (mesh, 100.64.0.0/10)  │
          ┌────────────┴────────────┐        ┌────────────┴─────────────┐
          │  STORAGE 30 (vmi3549084)│        │  STORAGE 10 (vmi3322106) │
          │  DBs pickpro + logto    │        │  DBs telemetry + minio   │
          │  minio pickpro (Docker) │        │  obs (Docker)            │
          └─────────────────────────┘        └──────────────────────────┘
```

## Machines

| Machine | Rôle | IP publique | IP Tailscale | vCPU / RAM | Héberge |
|---|---|---|---|---|---|
| **vmi3322097** | Control-plane k3s + **Headscale** (coordination Tailscale) | 84.247.188.175 | **100.64.0.1** | 4 / 8 GB | etcd, apiserver, headscale:8080 |
| **vmi3322098** | Worker k3s | 84.247.189.16 | **100.64.0.3** | 6 / 8 GB | pods applicatifs, CoreDNS |
| **vmi3322099** | Worker k3s | 84.247.189.239 | **100.64.0.2** | 6 / 8 GB | pods applicatifs |
| **vmi3322100** | Worker k3s | 84.247.190.97 | **100.64.0.4** | 6 / 8 GB | pods applicatifs |
| **vmi3549081** | Worker k3s | 173.212.219.98 | **100.64.0.6** | 6 / 8 GB | pods applicatifs |
| **vmi3549084** | **Storage VPS 30** — Docker stateful | 164.68.123.88 | **100.64.0.7** | 6 / 8 GB | DBs pickpro (prod+dev), postgres logto, minio pickpro (prod+dev) |
| **vmi3322106** | **Storage VPS 10** — Docker stateful | 37.60.225.137 | **100.64.0.5** | 2 / 3.8 GB | postgres telemetry, minio soludev (observability) |
| *(hors cluster)* MacBook de Yohan | Client tailnet | — | **100.64.0.8** | — | kubectl, tests |

> Les Storage VPS ne sont **pas dans le cluster k3s** (décision 7 sept 2026 :
> l'isolation totale exige Docker direct — le collector openobserve tolère
> tous les taints, l'option nœuds k3s aurait laissé des process étrangers).

## Réseau

- **Tailscale** (headscale sur vmi3322097:8080, cert autosigné CN=84.247.188.175)
  relie toutes les machines : `100.64.0.0/10`.
- **Flannel** (réseau pods k3s) roule sur `tailscale0` — les nœuds k3s
  communiquent via leurs IP Tailscale.
- **Accès externe** : Cloudflare Tunnel (`cloudflared` ×2 dans k8s) →
  traefik (k8s) → apps. RTT Vietnam↔edge CF ≈ 280 ms (PoP EU).
- **Sécurité Storage VPS** : services Docker bindés **uniquement** sur
  l'IP Tailscale + ufw (`deny in on eth0` ports 5432-5436/9030-9035,
  `allow 22`, `allow in on tailscale0`). Les DBs/MinIO sont **injoignables
  publiquement**.

## Données stateful — Docker sur les VPS Storage

### Storage 30 (100.64.0.7) — `/opt/pickpro-stack/docker-compose.yml`

| Conteneur | Port (bind 100.64.0.7) | Volume (données) | Servi par |
|---|---|---|---|
| `pgvector-pickpro-prod` | **5433** | `/srv/nfs/pickpro/pgvector` (153 Mo) | pickpro prod (api ×2, indexing ×2, notifications) |
| `pgvector-pickpro-dev` | **5434** | `/srv/nfs/pickpro-dev/pgvector` (66 Mo) | pickpro-dev (api, indexing, notifications) |
| `postgres-soludev` (logto) | **5435** | `/srv/nfs/soludev/postgres` (1.3 Go) | logto (via pgbouncer k8s:6432) |
| `minio-pickpro-prod` | **9030** | `/srv/nfs/pickpro/minio` (1.1 Go, 5197 photos) | pickpro prod (api, indexing) |
| `minio-pickpro-dev` | **9031** | `/srv/nfs/pickpro-dev/minio` | pickpro-dev (api, indexing) |
| `valkey-soludev` | **6379** | `/srv/nfs/soludev/valkey` | logto (REDIS_URL), pickpro prod+dev (VALKEY_HOST : api, indexing, notifications), sessions oauth2-proxy |

### Storage 10 (100.64.0.5) — `/opt/pickpro-stack/docker-compose.yml`

| Conteneur | Port (bind 100.64.0.5) | Volume | Servi par |
|---|---|---|---|
| `postgres-telemetry` | **5436** | `/srv/nfs/soludev/postgres` (2.8 Go) | phoenix, sonarqube, openobserve |
| `minio-soludev` | **9032** | `/srv/nfs/soludev/minio` | openobserve (S3 observability) |

Credentials : `/opt/pickpro-stack/.env` sur chaque VPS (chmod 600, hors git).
Composes versionnés : `flux/infra-vps/storage{10,30}/docker-compose.yml`.

## Services dans le cluster k3s

| Namespace | Service | Détail |
|---|---|---|
| `soludev` | **logto** | IAM ; DB via pgbouncer |
| `soludev` | **pgbouncer** | session mode :6432 → logto ; userlist auto-généré depuis OpenBao `soludev/pgbouncer` (rôles logto_tenant_*) |
| `soludev` | **openbao** | secrets (ClusterSecretStore → ExternalSecrets, refresh 60s) |
| `soludev` | **phoenix** | tracing LLM ; DB telemetry docker ; helm-managed |
| `soludev` | **sonarqube** | DB telemetry docker ; helm-managed |
| `soludev` | **openobserve** | logs/metrics ; DB + S3 telemetry docker |
| `soludev` | **nats**, **cloudflared** ×2, **headlamp** | infra |
| `pickpro` | **pickpro-api** ×2, **pickpro-indexing-api** ×2, **pickpro-notifications**, **pickpro-front**, **pickpro-landing**, **oauth2-proxy**, **cloudflared** ×2 | DB → docker :5433, MinIO → docker :9030 |
| `pickpro-dev` | idem (replicas 1) | DB → docker :5434, MinIO → docker :9031 |
| `ubby`, `openclaw` | apps | DBs encore en k8s (pgvector ubby : NFS) |

## Flux GitOps

- Repo : `SoluDevTech/flux` (push) → mirror `Kaiohz/flux` (lu par Flux)
- 6 Kustomizations : `soludev`, `pickpro`, `pickpro-dev`, `ubby`, `openclaw`, `cluster` (prune=true, interval 2 min)
- Helm-managed hors Flux : phoenix, sonarqube, oauth2-proxy prod, minio prod (retiré depuis) — patchs kubectl directs, values dans `config/prd/*/values.yaml`

## Secrets & connexions (OpenBao)

| Clé OpenBao | Contenu | Pointe vers |
|---|---|---|
| `pickpro/api` | DATABASE_URL, ALEMBIC_DATABASE_URL, MINIO_SECRET, clés LLM... | `@100.64.0.7:5433` |
| `pickpro/indexing`, `pickpro/notifications` | DATABASE_URL | `@100.64.0.7:5433` |
| `pickpro-dev/{api,indexing,notifications}` | idem | `@100.64.0.7:5434` |
| `soludev/pgbouncer` | DATABASE_URLS (logto + 2 rôles tenant) | `@100.64.0.7:5435` |
| `soludev/logto` | DB_URL (via pgbouncer), ADMIN_PASSWORD, KEK | `pgbouncer:6432` |
| `soludev/openobserve` | ZO_META_POSTGRES_DSN, MINIO_* | `@100.64.0.5:5436` + `:9032` |
| `soludev/pgbouncer`-style : `soludev/phoenix`, secrets minio... | | docker correspondants |

MinIO hosts (configmaps Flux, pas de secrets) : prod `100.64.0.7:9030`, dev `100.64.0.7:9031`.

## Règles opérationnelles (leçons de session)

1. Éteindre un pod définitivement = `git rm` du manifest (prune Flux),
   jamais seulement `kubectl scale 0` (rescalé à la reconcile).
2. Configmap édité = restart du pod (pas de hot-reload).
3. Bascule DSN d'une app = patch OpenBao (l'ExternalSecret écrase les
   patchs k8s en 60 s), puis restart pods.
4. Déplacer un postgres/minio = séquence : stop pod k8s → prune Flux →
   conteneur docker (même volume) → bascule OpenBao/configmap → restart apps.
   Jamais deux serveurs sur le même PGDATA.
5. Les adresses en dur dans les configs ([databases] pgbouncer, hosts
   helm values) cassent quand la cible bouge — les expliciter à chaque migration.
6. Backup : les PGDATA restent sur les VPS Storage (disque local) —
   prévoir des dumps cron croisés 30↔10 (à mettre en place).

## Historique récent

- **6 sept** : isolation télémétrie (postgres-telemetry k8s → Storage 10 NFS), migration Headscale → control-plane, pgbouncer devant logto, fixes photos/MinIO/throttling.
- **7 sept** : migration des données stateful vers Docker sur les VPS Storage (7 conteneurs), Mac rejoint le tailnet prd, thumbnails photos (code pickpro-back).
- **8 sept** : valkey k8s (PVC NFS) → Docker Storage 30 (`valkey-soludev:6379`, même volume, sessions oauth2-proxy incluses) ; dnsConfig ndots=1 généralisé (logto, pgbouncer, oauth2-proxy, pickpro) ; sessions oauth2-proxy dev en store Redis ; app Logto PickPro Dev alignée prod (refresh token 14 j, postLogoutRedirectUris).
- **9 sept** : backfill thumbnails photos prod (5198/5198, Job one-shot) ; stabilité cluster — CoreDNS scalé à 4 (1/worker, patch direct helm-managed k3s : peut être ré-écrasé par un upgrade k3s, re-vérifier `kubectl scale deployment coredns -n kube-system --replicas=4`) ; probes openobserve assouplies (liveness timeout 1s→5s, ft 3→10 : le crash-loop 43 restarts dégradait le réseau du node vmi3322098, latences valkey p95 146ms→13ms après fix).