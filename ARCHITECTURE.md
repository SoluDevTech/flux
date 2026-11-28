# Architecture — Cluster K3s SoluDev + VPS Storage

Dernière mise à jour : 28 novembre 2026

## Vue d'ensemble

```
                        ┌─────────────────────────────────────────┐
                        │           INTERNET (utilisateurs)      │
                        └──────────────────┬──────────────────────┘
                                           │
                                Cloudflare (DNS, tunnel)
                                           │ cloudflared ×4 (k8s)
                ┌──────────────────────────┴───────────────────────────┐
                │           CLUSTER K3S — 10 nœuds                    │
                │                                                     │
                │  control-plane + 4 workers compute (untainted)      │
                │  tous les pods stateless                            │
                │                                                     │
                │  ┌───────────────┐ ┌───────────────┐ ┌─────────────┐ │
                │  │ PG-PICKPRO    │ │ STORAGE30-B   │ │ STORAGE30-C │ │
                │  │ vmi3794476    │ │ vmi3794485    │ │ vmi3794484  │ │
                │  │ Plus 6 (NVMe) │ │ Storage VPS30 │ │ Storage 30  │ │
                │  │ .8 — TAINTED  │ │ .10 — TAINTED │ │ .11 — TAINTED│ │
                │  │ pgvector prod │ │ rustfs prod   │ │ telemetry + │ │
                │  │               │ │ (1 TB)        │ │ rustfs-OO   │ │
                │  └───────────────┘ └───────────────┘ └─────────────┘ │
                │  ┌───────────────┐ ┌─────────────────────────────┐  │
                │  │ STORAGE 10    │ │ STORAGE 30 (vmi3549084, .7) │  │
                │  │ vmi3322106 .5 │ │ — TAINTED                   │  │
                │  │ — TAINTED     │ │ logto, pgvector mutualisé   │  │
                │  │ NATS (JS 20Gi)│ │ dev+composables, rustfs dev,│  │
                │  │ (réservé      │ │ serveur NFS (openbao/OO/     │  │
                │  │  backup)      │ │ sonarqube/ubby)              │  │
                │  └───────────────┘ └─────────────────────────────┘  │
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
| **vmi3794476** | **Cloud VPS Plus 6** — Agent k3s TAINTÉ (label `pg-pickpro`) | 77.216.136.150 | **100.64.0.8** | 6 / 12 GB / 300 GB NVMe (fio 75k IOPS 4K) | pgvector pickpro prod (PV local) |
| **vmi3794485** | **Storage VPS 30** — Agent k3s TAINTÉ (label `storage30-b`) | 77.216.136.160 | **100.64.0.10** | 6 / 18 GB / 1 TB SSD (fio 16k IOPS) | rustfs-pickpro prod (PV local 50Gi) |
| **vmi3794484** | **Storage VPS 30** — Agent k3s TAINTÉ (label `storage30-c`) | 77.216.136.159 | **100.64.0.11** | 6 / 18 GB / 1 TB SSD (fio 19k IOPS) | postgres-telemetry + rustfs-soludev (PV local) |
| **vmi3549084** | **Storage VPS 30** — Agent k3s TAINTÉ (label `storage30`) | 164.68.123.88 | **100.64.0.7** | 6 / 8 GB | postgres logto, pgvector mutualisé dev+composables, rustfs-pickpro-dev, rustfs-composables (PV local) + serveur NFS |
| **vmi3322106** | **Storage VPS 10** — Agent k3s TAINTÉ (label `storage10`) | 37.60.225.137 | **100.64.0.5** | 2 / 4 GB | NATS (JetStream, PV local 20Gi) ; **réservé backup** |
| *(hors cluster)* MacBook de Yohan | Client tailnet | — | **100.64.0.9** | — | kubectl, tests |

> 27-28 nov 2026 : **séparation par profil d'I/O** — la DB pickpro prod a son
> node NVMe dédié (`pg-pickpro`), le S3 pickpro prod son Storage 30 dédié
> (`storage30-b`), l'observabilité quitte le Storage VPS 10 pour un Storage 30
> dédié (`storage30-c`), NATS prend la place libérée sur Storage 10. Tous les
> nouveaux nodes rejoignent le cluster comme les précédents : agents k3s
> taintés `storage/role=data:NoSchedule` via Tailscale
> (`--node-ip 100.64.0.x --flannel-iface tailscale0`, version pinnée
> `v1.37.0+k3s1`), labels `storage/nodename=<label>` + `storage/role=data`.
> Dimensionnement **80/20** : limits pods = 80 % de la RAM du node, 20 %
> réservés au système (kubelet, k3s agent, tailscaled) ; sur les nodes
> partagés (storage30-c, storage10, storage30) le budget se répartit entre
> cohabitants.

## Réseau

- **Tailscale** (headscale plateau vmi3322097:8080, https, cert auto-signé
  installé dans le trust store de chaque node : `/usr/local/share/ca-certificates/headscale*.crt`)
  relie les machines : `100.64.0.0/10`.
- **Flannel VXLAN** passe sur `tailscale0` — agents storage lancés avec
  `--node-ip 100.64.0.x --flannel-iface tailscale0` (le default=
  VXLAN qui passerait par les IP publiques eth0 bloquerait absurdement
  les tunnels UDP 8472 entre zones dégeolocalisées).
- **Piège headscale (27 nov)** : l'enregistrement d'un nouveau node n'actualise
  pas le netmap des nodes déjà connectés (vmi3549081 ne voyait pas les 3
  nouveaux). Fix : `systemctl restart tailscaled && systemctl restart k3s-agent`
  (jamais tailscaled seul : les routes VXLAN flannel ne se reconstruisent
  pas seules).
- **Accès externe** : Cloudflare Tunnel (cloudflared ×2 soludev, ×2 pickpro)
  → traefik (k8s) → apps.
- **Sécurité** : le taint protège les storage nodes (scheduling) ;
  ufw sur les VPS bloque tout sauf SSH + tailnet. L'AWS-like zone
  de confiance est le mesh Tailscale (mTLS headscale auth).

## Données stateful — Pods k8s sur disque local

### pg-pickpro (100.64.0.8) — agent tainté, dédié DB

| Workload | Image | Données (PV local, nodeAffinity) | Servi par |
|---|---|---|---|
| `pgvector` pickpro | `pgvector/pgvector:0.8.0-pg17` | PV v2 `local-pickpro-pgvector-v2` 20Gi, `/srv/nfs/pickpro/pgvector` | pickpro prod (api, indexing, notifications) |

> limits 9Gi/4800m (80 % du Plus 6 12 GB), tuning
> `shared_buffers=2GB`, `effective_cache_size=6GB`, `maintenance_work_mem=1GB`.
> Migré le 27 nov par dump/restore (128 Mo, 28 tables, counts identiques) ;
> **PV v1 + anciennes données disque supprimés le 28 nov** (validation user).

### storage30-b (100.64.0.10) — agent tainté, dédié S3 pickpro

| Workload | Image | Données (PV local, nodeAffinity) | Servi par |
|---|---|---|---|
| `rustfs-pickpro` (helm chart `rustfs/rustfs` 1.0.6) | `rustfs/rustfs:1.0.6` | PV v2 `local-pickpro-rustfs-v2` 50Gi, `/srv/nfs/pickpro/rustfs` (cvs, photos, transcripts — 1 TB de marge) | pickpro prod (api, indexing) |

> limits 8Gi/4000m. Migré le 27 nov par `mc mirror` (20891 objets / 5.8 GiB,
> buckets cvs 10056 + photos 10835 vérifiés SRC=DST) ; release name inchangé
> → `rustfs-pickpro-svc:9000` et configmaps `MINIO_HOST` intacts. **PV v1 +
> anciennes données disque supprimés le 28 nov** (validation user). Scanner
> toujours `slow`, à repasser `standard` après une semaine de métriques.

### storage30-c (100.64.0.11) — agent tainté, observabilité

| Workload | Image | Données (PV local, nodeAffinity) | Servi par |
|---|---|---|---|
| `postgres-telemetry` | `postgres:17-alpine` | PV v2 `local-soludev-telemetry-postgres-v2` 20Gi, `/srv/nfs/soludev/postgres` (bases openobserve, phoenix, sonarqube) | phoenix, sonarqube, openobserve |
| `rustfs-soludev` (helm chart `rustfs/rustfs` 1.0.6) | `rustfs/rustfs:1.0.6` | PV v2 `local-soludev-rustfs-v2` 50Gi, `/srv/nfs/soludev/rustfs` (bucket `observability`) | openobserve S3 (ZO_S3_PROVIDER=s3) |

> Budget 80/20 partagé : telemetry 8Gi/2800m + rustfs-soludev 6Gi/2000m.
> 28 nov (après-midi) : **rétention OO portée de 10 à 45 jours**
> (`ZO_COMPACT_DATA_RETENTION_DAYS=45`) — débit mesuré ~5,7 Go/jour →
> 45j ≈ 260-500 Go, confortable sur ~945 Go libres. Phoenix : aucune
> modification nécessaire, il ne purge jamais (historique complet
> conservé dans sa base postgres, 1,4 Go à ce jour).
> 28 nov : **postgres-telemetry migré par copie physique** (rsync pass-1 à
> chaud 15 Go + delta à l'arrêt — users OpenObserve/dashboards/alerts
> intégralement préservés) ; **rustfs-soludev repart sur bucket NEUF**
> (décision utilisateur : l'historique logs/metrics/traces — ~110 Go /
> 10,2 M fichiers, trop lent à transférer depuis le VPS 10 — est sacrifié).
> **PVs v1 + anciennes données disque supprimés le 28 nov** (validation
> user). Garde-fous rustfs conservés (scanner `slow`, `timeout_profile
> high_latency`, probes tolérantes — héritage des stalls I/O storage10,
> cf. 81 restarts/22h oct 2026) — à relâcher après une semaine sans stall.

### storage30 (100.64.0.7) — agent tainté

| Workload | Image | Données (PV local, nodeAffinity) | Servi par |
|---|---|---|---|
| `postgres` (logto) | `postgres:17-alpine` | `/srv/nfs/soludev/postgres` | logto via pgbouncer (k8s:6432) |
| `pgvector` mutualisé dev+composables | `kaiohz/pickpro:postgres-raganything-*` (postgres 17 + age/pg_textsearch/vector, `shared_preload_libraries=pg_textsearch`) | `/srv/nfs/pickpro-dev/pgvector` — bases `pickpro` + `raganything` | pickpro-dev (api, indexing, notifications) + composable-agents, raganything |
| `rustfs-pickpro-dev` (helm) | `rustfs/rustfs:1.0.6` | `/srv/nfs/pickpro-dev/rustfs` | pickpro-dev |
| `rustfs-composables` (helm) | idem | `/srv/nfs/composables/rustfs` | composable-agents (MCP/docs), raganything (fichiers) |

> 28 nov : **mutualisation postgres dev+composables** — l'instance pgvector
> pickpro-dev absorbe la base `raganything` (l'ancienne instance postgres
> composables est retirée ; **l'ancien répertoire disque
> `/srv/nfs/composables/postgres` a été supprimé le 28 nov**, validation
> user). Le rôle `raganything` est `BYPASSRLS` (il était
> bootstrap superuser dans l'ancienne instance, bypassant les policies RLS).
> Les secrets OpenBao `composables/{raganything,composable-agents}` pointent
> désormais sur `pgvector.pickpro-dev.svc.cluster.local:5432`.
> Budget 80/20 : logto 2Gi + pgvector mutualisé 2Gi/1000m + rustfs-dev 1Gi/1000m
> + rustfs-composables 1Gi/1000m ≈ 5Gi/6.4 disponibles (NFS host dans les 20 %).

### storage10 (100.64.0.10 = 100.64.0.5) — agent tainté

| Workload | Image | Données (PV local, nodeAffinity) | Servi par |
|---|---|---|---|
| `nats` (helm chart nats 2.14.6, server 2.14.9-alpine) | `nats:2.14.9-alpine` | PV `local-soludev-nats` 20Gi, `/srv/nfs/soludev/nats` (JetStream : streams RESUMES, NOTIFICATIONS, MASS_IMPORT_COMPLETED + -DEV) | pickpro api/indexing/notifications prod+dev (mass-import, transcripts) |

> 27 nov : NATS quitte son PVC local-path non pincé (worker aléatoire) pour
> un PV local déterministe sur storage10. limits 2Gi/1000m. Migration rsync
> à froid (404 KB, streams + messages en attente intacts). **Toujours pinner
> `--version 2.14.6`** sur les upgrades helm nats (un upgrade non pinné a
> déployé 2.15.0, 11 breaking changes). `podTemplate.merge.spec` pour
> nodeSelector/tolerations (merge à plat = ignoré par l'apiserver).
> Le node reste réservé au futur chantier backup. **PVs v1 supprimés le
> 28 nov** (validation user) ; ancien PGDATA telemetry + ancien bucket
> observability supprimés du disque.

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
| `soludev` | **postgres** + **postgres-telemetry** | instances k8s, PV local node-pinned (storage30 / storage30-c) |
| `soludev` | **openbao** | secrets (ClusterSecretStore → ExternalSecrets 60s) |
| `soludev` | **phoenix**, **sonarqube**, **openobserve** | DB → postgres-telemetry interne; openobserve S3 → rustfs-soludev interne (provider s3, path-style) |
| `soludev` | **rustfs-soludev** (helm chart rustfs 1.0.6) | observabilité ; creds OpenBao `soludev/rustfs` |
| `soludev` | **nats** (helm chart 2.14.6, node-pinned storage10), cloudflared ×2, headlamp | infra |
| `pickpro` | pickpro-api ×2, indexing ×2, notifications, front, landing, oauth2-proxy, cloudflared ×2 | DB → `pgvector.pickpro:5432` (node pg-pickpro), RustFS → `rustfs-pickpro-svc:9000` (node storage30-b), NATS → `nats.soludev:4222` (node storage10) |
| `pickpro-dev` | idem (replicas réduits) | DB → `pgvector.pickpro-dev:5432` (instance mutualisée avec composables), RustFS → `rustfs-pickpro-dev-svc:9000` |
| `composables` | composable-agents, composable-ui, raganything, oauth2-proxy (helm), rustfs | DB → `pgvector.pickpro-dev:5432` (base `raganything`), RustFS → `rustfs-composables-svc:9000`, UI ingress `composables.soludev.tech` + agents `composables-agent.soludev.tech` + rag `raganything.soludev.tech` (forwardAuth oauth2-proxy) |

## Flux GitOps

- Repo : `SoluDevTech/flux` (push = flux sync en 1-2 min)
- Kustomizations : `soludev`, `pickpro`, `pickpro-dev`, `cluster`,
  `composables`
  (prune=true, interval 2 min, wait=true pour apps)
- Helm-managed (install manuel via helm CLI, values versionnées dans
  `config/prd/*`) : openbao, phoenix, sonarqube, openobserve, oauth2-proxy,
  nats (**pinner --version**), **rustfs-soludev, rustfs-pickpro,
  rustfs-pickpro-dev, rustfs-composables** (chart `rustfs/rustfs`,
  repo `https://charts.rustfs.com`, **toujours pinner --version**)
- Manifests Flux raw : logto, pgbouncer, cloudflared, headlamp,
  postgres, postgres-telemetry, pgvector ×2 (prod sur pg-pickpro,
  mutualisé sur storage30), PVs locaux v2 (`local-pickpro-pgvector-v2`,
  `local-pickpro-rustfs-v2`, `local-soludev-telemetry-postgres-v2`,
  `local-soludev-rustfs-v2`, `local-soludev-nats`), ExternalSecrets,
  configmaps consumers

## Secrets & connexions (OpenBao)

| Clé OpenBao | Pointe vers (post-28 nov) |
|---|---|
| `pickpro/{api,indexing,notifications}` | `@pgvector.pickpro.svc.cluster.local:5432` ; api: `MINIO_SECRET` (paire rustfs) ; configmap `MINIO_HOST` → `rustfs-pickpro-svc:9000` |
| `pickpro-dev/{api,indexing,notifications}` | `@pgvector.pickpro-dev.svc.cluster.local:5432` ; `MINIO_ACCESS`/`MINIO_SECRET` (paire `pickpro-dev-rustfs`) |
| `pickpro/rustfs` | creds root RustFS prod (`RUSTFS_ACCESS`/`RUSTFS_SECRET`) |
| `pickpro-dev/rustfs` | creds root RustFS dev (`RUSTFS_ACCESS`/`RUSTFS_SECRET`) |
| `soludev/rustfs` | creds root RustFS observabilité (`RUSTFS_ACCESS`/`RUSTFS_SECRET`) |
| `soludev/nats` | password NATS (secret `nats-auth`, user `pickpro`) |
| `composables/rustfs` | creds root RustFS composables (`RUSTFS_ACCESS`/`RUSTFS_SECRET`) |
| `composables/{raganything,composable-agents}` | `DATABASE_URL` → `postgresql://raganything@pgvector.pickpro-dev.svc.cluster.local:5432/raganything` (mutualisation 28 nov) ; API keys OpenAI/Phoenix/Bricks inchangées |
| `composables/{composable-ui,oauth2-proxy}` | inchangés |
| `soludev/pgbouncer` | `@postgres.soludev.svc.cluster.local:5432` |
| `soludev/logto` | pgbouncer.soludev.svc.cluster.local:6432 (inchangé) |
| `soludev/openobserve` | `@postgres-telemetry.soludev...:5432` ; storage `rustfs-soludev-svc:9000` (creds via secret `rustfs-soludev`) ; clés `MINIO_*` obsolètes |
| `soludev/{phoenix,sonarqube}` secrets | postgres-telemetry interne (host/jdbcUrl aussi dans values git) |
| `pickpro-docker-secret` (×3 ns) | dockerconfigjson `docker.io` user kaiohz — **le repo Docker Hub `kaiohz/pickpro` est privé** : tout pod d'une image `kaiohz/pickpro:*` sur un node sans cache DOIT avoir `imagePullSecrets` |

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
- **13 oct** : **migration MinIO → RustFS** (chart officiel
  `rustfs/rustfs` 1.0.1, values `config/prd/rustfs/<ns>/values.yaml`,
  PV/PVC/ExternalSecrets raw Flux dans `prd/<ns>/rustfs/`) sur les 3
  namespaces : pickpro, pickpro-dev (mirror `mc` complet vérifié :
  cvs 9672, photos 10613) et soludev (OpenObserve via
  `ZO_S3_PROVIDER=s3`, creds OpenBao `*/rustfs`) ; les 3 anciens MinIO
  **supprimés** (helm uninstall, PV/PVC, data disque, manifests repo).
- **8 nov** : **retour de la plateforme composables** (restauration
  depuis 22e3a85^) directement en **RustFS** : helm
  `rustfs-composables` (storage30, `/srv/nfs/composables/rustfs`,
  values `config/prd/rustfs/composables/values.yaml`), PV local
  `/srv/nfs/composables/postgres` **repris avec les données d'époque**
  (RAG pgvector inchangées), namespace + Kustomization Flux
  `prd/composables` (prune on). Données buckets vérifiées SRC=DST.
- **27-28 nov** : **séparation des données par profil d'I/O** (plan
  « pickpro prod / dev-composables / ops ») :
  - 3 nouveaux nodes Contabo (Cloud VPS Plus 6 + 2 × Storage VPS 30,
    même zone 77.216.136.x) : `pg-pickpro`, `storage30-b`, `storage30-c` ;
    agents taintés, fio validé (75k / 16k / 19k IOPS 4K vs baseline
    storage30 ≈ 8k) ; certificats headscale installés dans le trust
    store (sinon `x509: certificate signed by unknown authority`).
  - **pgvector pickpro prod → pg-pickpro** (dump/restore, 128 Mo,
    validation row counts ; 9Gi/4800m, tuning NVMe).
  - **rustfs-pickpro prod → storage30-b** (mc mirror 20891 objets,
    8Gi/4000m ; PVC logs héritée supprimée au passage).
  - **NATS → storage10** (rsync à froid, PV 20Gi pincé, 2Gi/1000m ;
    charts helm TOUJOURS pinnés — incident 2.15.0 corrigé).
  - **Incident réseau** : netmap tailscale périmé sur vmi3549081
    (nouveaux peers invisibles → CrashLoop pickpro-api) ; fix
    tailscaled + k3s-agent.
  - **Découverte** : repo Docker Hub `kaiohz/pickpro` privé →
    imagePullSecret `pickpro-docker-secret` requis partout.
  - **Observabilité → storage30-c** : postgres-telemetry (copie physique
    PGDATA 15 Go, 8Gi/2800m, shared_buffers 2GB — users/config OpenObserve
    intégralement préservés) + rustfs-soludev (bucket NEUF : l'historique
    ~110 Go / 10,2 M fichiers trop lent à transférer depuis le VPS 10,
    décision utilisateur de le sacrifier — ancien bucket conservé sur
    disque storage10 ; 6Gi/2000m, garde-fous conservés).
  - **Mutualisation postgres dev+composables** : la base `raganything`
    rejoint l'instance pgvector pickpro-dev (image RAG, extensions
    age/pg_textsearch/vector, preload pg_textsearch, BYPASSRLS) ;
    instance postgres composables supprimée ; secrets OpenBao repointés.
  - PVs v1 de toutes les migrations : **objets k8s prunés + données disque
    supprimées le 28 nov** (validation user) — ancien PGDATA telemetry et
    ancien bucket observability (~110 Go) sur storage10, anciens pgvector/
    rustfs pickpro prod sur storage30, ancienne instance postgres
    composables.
