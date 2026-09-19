# Architecture — Cluster K3s SoluDev + VPS Storage

Dernière mise à jour : 19 septembre 2026

## Vue d'ensemble

```
                        ┌─────────────────────────────────────────┐
                        │           INTERNET (utilisateurs)      │
                        └──────────────────┬──────────────────────┘
                                           │
                                Cloudflare (DNS, tunnel)
                                           │ cloudflared ×4 (k8s)
                ┌──────────────────────────┴───────────────────────────┐
                │           CLUSTER K3S — 7 nœuds                     │
                │                                                     │
                │  control-plane + 4 workers compute (untainted)      │
                │  tous les pods stateless                            │
                │                                                     │
                │  ┌─────────────────────────┐  ┌──────────────────┐  │
                │  │ STORAGE 30 vmi3549084   │  │ STORAGE 10       │  │
                │  │ 100.64.0.7 — TAINTED    │  │ vmi3322106 .5    │  │
                │  │ postgres + pgvector ×2  │  │ — TAINTED        │  │
                │  │ minio ×2 (disque local) │  │ postgres-telemetry│ │
                │  │                         │  │ + minio-soludev  │  │
                │  └─────────────────────────┘  └──────────────────┘  │
                │   (valkey + serveur NFS : docker/hors k8s)          │
                └─────────────────────────────────────────────────────┘
```

## Machines

| Machine | Rôle | IP publique | IP Tailscale | vCPU / RAM | Héberge |
|---|---|---|---|---|---|
| **vmi3322097** | Control-plane k3s + **Headscale** (coordination Tailscale) | 84.247.188.175 | **100.64.0.1** | 4 / 8 GB | etcd, apiserver, headscale:8080 |
| **vmi3322098** | Worker k3s | 84.247.189.16 | **100.64.0.3** | 6 / 8 GB | pods compute |
| **vmi3322099** | Worker k3s | 84.247.189.239 | **100.64.0.2** | 6 / 8 GB | pods compute |
| **vmi3322100** | Worker k3s | 84.247.190.97 | **100.64.0.4** | 6 / 8 GB | pods compute |
| **vmi3549081** | Worker k3s | 173.212.219.98 | **100.64.0.6** | 6 / 8 GB | pods compute |
| **vmi3549084** | **Storage VPS 30** — Agent k3s TAINTÉ | 164.68.123.88 | **100.64.0.7** | 6 / 8 GB | postgres logto, pgvector prod+dev, minio prod+dev (PV local) |
| **vmi3322106** | **Storage VPS 10** — Agent k3s TAINTED | 37.60.225.137 | **100.64.0.5** | 2 / 3.8 GB | postgres-telemetry, minio-soludev (PV local) |
| *(hors cluster)* MacBook de Yohan | Client tailnet | — | **100.64.0.8** | — | kubectl, tests |

> 19 sept 2026 : les Storage VPS rejoignent le cluster comme **agents
> k3s taintés** `storage/role=data:NoSchedule` — seuls les workloads
> minio/postgres/pgvector y sont tolérés (nodeSelector + toleration).
> Le docker-direct de la période 7-19 sept est remplacé : tout redevance
> k8s/Flux. Restent hors k8s : `valkey-soludev` (Docker Storage 30) et
> le serveur **NFS** de Storage 30 (couche stockage pour openbao /
> openobserve / sonarqube — pas un workload k8s, le taint ne la concerne pas).

## Réseau

- **Tailscale** (headscale plateau vmi3322097:8080) relie les machines :
  `100.64.0.0/10`.
- **Flannel VXLAN** passe sur `tailscale0` — agents storage lancés avec
  `--node-ip 100.64.0.x --flannel-iface tailscale0` (le default=
  VXLAN qui passerait par les IP publiques eth0 bloquerait absurdement
  les tunnels UDP 8472 entre zones dégeolocalisées).
- **Accès externe** : Cloudflare Tunnel (cloudflared ×2 soludev, ×2 pickpro)
  → traefik (k8s) → apps.
- **Sécurité** : le taint protège les storage nodes (scheduling) ;
  ufw sur les VPS bloque toujours les ports DB publics. L'AWS-like zone
  de confiance est le mesh Tailscale (mTLS headscale auth).

## Données stateful — Pods k8s sur disque local

### Storage 30 (100.64.0.7) — agent tainté

| Workload | Image | Données (PV local, nodeAffinity) | Servi par |
|---|---|---|---|
| `postgres` (logto) | `postgres:17-alpine` | `/srv/nfs/soludev/postgres` (~1.3 Go) | logto via pgbouncer (k8s:6432) |
| `pgvector` pickpro | `pgvector/pgvector:0.8.0-pg17` | `/srv/nfs/pickpro/pgvector` | pickpro prod (api, indexing, notifications) |
| `pgvector` pickpro-dev | idem | `/srv/nfs/pickpro-dev/pgvector` | pickpro-dev |
| `minio-pickpro` (helm) | `RELEASE.2025-09-07T16-13-09Z` | `/srv/nfs/pickpro/minio` (cvs, photos, transcripts) | pickpro prod |
| `minio-pickpro-dev` (Deployment raw Flux) | idem | `/srv/nfs/pickpro-dev/minio` | pickpro-dev |

### Storage 10 (100.64.0.5) — agent tainté

| Workload | Image | Données (PV local) | Servi par |
|---|---|---|---|
| `postgres-telemetry` | `postgres:17-alpine` | `/srv/nfs/soludev/postgres` (~3 Go, le disque Storage **10**) | phoenix, sonarqube, openobserve |
| `minio-soludev` (helm) | `RELEASE.2024-12-18T13-15-44Z` | `/srv/nfs/soludev/minio` (bucket `observability`) | openobserve S3 |

Server (hors k8s, docker Storage 30, mesh Tailscale only) :

| Conteneur | Port | Volume | Servi par |
|---|---|---|---|
| `valkey-soludev` | 6379 | `/srv/nfs/soludev/valkey` | logto (REDIS_URL), pickpro VALKEY_HOST ×6, sessions oauth2-proxy |
| serveur **NFS nfsd** (Storage 30) | 2049 | `/srv/nfs/*` | PVs `nfs-soludev-{openbao,openobserve,sonarqube}` + ubby/back |

## Services dans le cluster k3s

| Namespace | Service | Détail |
|---|---|---|
| `soludev` | **logto** | IAM ; DB via pgbouncer (6432) → `postgres.soludev.svc...` |
| `soludev` | **pgbouncer** | session mode :6432 → logto ; userlist auto-généré depuis OpenBao `soludev/pgbouncer` |
| `soludev` | **postgres** + **postgres-telemetry** | instances k8s, PV local node-pinned |
| `soludev` | **openbao** | secrets (ClusterSecretStore → ExternalSecrets 60s) |
| `soludev` | **phoenix**, **sonarqube**, **openobserve** | DB → postgres-telemetry interne; openobserve S3 → minio-soludev interne |
| `soludev` | **minio-soludev** (helm) | observabilité ; image chart 5.4.0 |
| `soludev` | nats (local-path), cloudflared ×2, headlamp | infra |
| `pickpro` | pickpro-api ×2, indexing ×2, notifications, front, landing, oauth2-proxy, cloudflared ×2 | DB → `pgvector.pickpro:5432`, MinIO → `minio-pickpro:9000` |
| `pickpro-dev` | idem (replicas 1) | DB → `pgvector.pickpro-dev:5432`, MinIO → `minio-pickpro-dev:9000` |

## Flux GitOps

- Repo : `SoluDevTech/flux` (push = flux sync en 1-2 min)
- Kustomizations : `soludev`, `pickpro`, `pickpro-dev`, `cluster`
  (prune=true, interval 2 min, wait=true pour apps)
- Helm-managed (install manuel via helm CLI, values versionnées dans
  `config/prd/*`) : openbao, phoenix, sonarqube, openobserve, oauth2-proxy,
  nats, **minio-soludev**, **minio-pickpro**
- Manifests Flux raw : logto, pgbouncer, cloudflared, headlamp,
  postgres, postgres-telemetry, pgvector ×2, minio-pickpro-dev,
  ingresses, PVs locaux, ExternalSecrets

## Secrets & connexions (OpenBao)

| Clé OpenBao | Pointe vers (post-19 sept) |
|---|---|
| `pickpro/{api,indexing,notifications}` | `@pgvector.pickpro.svc.cluster.local:5432` (+ `MINIO_HOST` configmap → `minio-pickpro:9000`) |
| `pickpro-dev/{api,indexing,notifications}` | `@pgvector.pickpro-dev.svc.cluster.local:5432` |
| `soludev/pgbouncer` | `@postgres.soludev.svc.cluster.local:5432` |
| `soludev/logto` | `pgbouncer.soludev.svc.cluster.local:6432` (inchangé) |
| `soludev/openobserve` | `@postgres-telemetry.soludev...:5432` + `http://minio-soludev...:9000` |
| `soludev/{phoenix,sonarqube}` secrets | postgres-telemetry interne (host/jdbcUrl aussi dans values git) |

## Règles opérationnelles (MAJ 19 sept)

1. **Éteindre un pod définitivement** = `git rm` du manifest (prune
   Flux), jamais un simple `kubectl scale 0`.
2. **Configmap édité** = restart/éviction du pod → nouveau env.
3. **Bascule DSN** = picher OpenBao (read-modify-write, hosts seulement)
   → l'ExternalSecret re-sync en 60s → évincer les pods : ils re-lisent.
4. **Déplacer un postgres/minio** = stop docker/pod source → diffuser
   manifests fautifs → data dir identique via PV local (nodeAffinity) →
   OpenBao host patch → pods consumers redémarrés. **Jamais deux
   serveurs sur le même PGDATA.**
5. **Le securityContext du chart MinIO (uid 1000) déclenche un
   `chown -R` de millions de fichiers à chaque mount** — à laisser OFF
   (`securityContext.enabled: false`) pour les volumes chargés.
6. **Version MinIO** ≥ version qui a écrit les données (XL-meta v3
   depuis `RELEASE.2025-09-07T16-13-09Z`).
7. **Agent k3s** = `--node-ip <tailscale-IP> --flannel-iface
   tailscale0` + re-patch taint après tout re-register de nœud.
8. **Backup** : PGDATA restent sur les disques Storage 30/10 —
   des dumps cron croisés restent à mettre en place.

## Historique

- **6 sept** : isolation télémétrie, Headscale → control-plane, pgbouncer devant logto, fixes photos/MinIO/throttling.
- **7 sept** : données stateful → Docker sur les VPS Storage (7 conteneurs).
- **8 sept** : valkey k8s → Docker Storage 30 ; oauth2-proxy sessions Redis ; dnsConfig ndots=1.
- **9 sept** : backfill thumbnails photos ; CoreDNS ×4 ; probes openobserve robustes.
- **19 sept** : **les Storage VPS sont dans le cluster** (agents taintés
  via Tailscale, `--flannel-iface tailscale0`) ; tout le stateful
  postgres/pgvector/minio redevance k8s en **PV local** sur les disques
  des VPS (mêmes chemins), binômes URLs → `*.svc.cluster.local` via
  OpenBao + configmaps ; minio pickpro + soludev en Helm VALUES
  versionnées ; opentrack du docker (valkey reste dockerisé).
