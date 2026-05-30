# Dev Cluster Tailscale Networking Fix

Documentation du fix réseau Tailscale/Flannel pour le cluster dev.

> **Pourquoi pas de manifests Kubernetes ?**
> K3s exécute Flannel en mode **embedded** (pas comme un DaemonSet séparé). Les annotations
> `flannel.alpha.coreos.com/public-ip-overwrite` sont ignorées par K3s — le VTEP IP est
> déterminé par l'interface réseau sélectionnée via `--flannel-iface` ou l'auto-détection.
> Le seul fix fiable est la configuration directe dans `/etc/rancher/k3s/config.yaml` sur
> chaque node physique, puis restart du service k3s/k3s-agent.

## Problème constaté

Le cluster dev utilise `--node-external-ip` et `--node-ip` pointant vers les IPs Tailscale,
mais **Flannel n'etait pas configuré pour utiliser `tailscale0` comme interface VXLAN**.
Résultat :
- `flannel.alpha.coreos.com/public-ip` pointait vers les IPs LAN (192.168.x.x / 192.168.5.1)
- lenovo (control plane) n'avait pas `--node-ip` — son INTERNAL-IP était `192.168.1.4`
- Le VXLAN overlay passait par le réseau local au lieu de Tailscale

## Fix appliqué (via SSH directe)

### jetson-desktop (worker)

```bash
ssh jetson@192.168.1.6
sudo tee /etc/rancher/k3s/config.yaml <<'K3SCONFIG'
server: https://100.64.0.6:6443
token: K107fc78042caa752981f08e98525cbd7822bded4ea81763839530e0d69464da9f6::server:c0b297b777ec9d68161c0327a0eb1b8c
node-external-ip: 100.64.0.7
node-ip: 100.64.0.7
flannel-iface: tailscale0
kube-proxy-arg: --proxy-mode=iptables
K3SCONFIG
sudo systemctl restart k3s-agent
```

### colima (VM Mac Mini)

```bash
# Via Tailscale IP
ssh root@100.64.0.4
sudo tee /etc/rancher/k3s/config.yaml <<'K3SCONFIG'
server: https://100.64.0.6:6443
token: K107fc78042caa752981f08e98525cbd7822bded4ea81763839530e0d69464da9f6::server:c0b297b777ec9d68161c0327a0eb1b8c
node-external-ip: 100.64.0.4
node-ip: 100.64.0.4
flannel-iface: tailscale0
kube-proxy-arg: --proxy-mode=iptables
K3SCONFIG
sudo systemctl restart k3s-agent
```

### lenovo (control plane)

**Attention :** le changement de `node-ip` sur un control plane avec etcd existant **casse etcd**
car l'URL du membre etcd est déjà enregistrée avec l'ancienne IP.

**Prérequis :** mettre à jour l'URL du membre etcd AVANT le restart :

```bash
ssh kaiohz@192.168.1.4

# 1. Installer etcdctl
sudo apt-get install -y etcd-client

# 2. Mettre à jour l'URL du membre etcd
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
  member update 21d2a2dba9df4b02 \
  --peer-urls=https://100.64.0.6:2380

# 3. Mettre à jour la config K3s
sudo tee /etc/rancher/k3s/config.yaml <<'K3SCONFIG'
cluster-init: true
kube-proxy-arg: --proxy-mode=iptables
node-external-ip: 100.64.0.6
node-ip: 100.64.0.6
flannel-iface: tailscale0
write-kubeconfig-mode: "0644"
K3SCONFIG

# 4. Restart
sudo systemctl restart k3s
```

## Vérification post-fix

```bash
# 1. Tous les nodes doivent avoir INTERNAL-IP = Tailscale IP
kubectl get nodes -o wide

# 2. Flannel public-ip doit être sur Tailscale
for n in lenovo colima jetson-desktop; do
  kubectl get node $n -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{"\n"}'
done

# 3. Les VXLAN FDB entries doivent pointer vers Tailscale IPs
# Depuis lenovo :
ssh kaiohz@192.168.1.4 'bridge fdb show dev flannel.1'
# Attendu : dst 100.64.0.4 (colima) et dst 100.64.0.7 (jetson)
```

## Résultat

| Node | Flannel VTEP IP (avant) | Flannel VTEP IP (après) |
|------|------------------------|------------------------|
| lenovo | 192.168.1.4 | 100.64.0.6 |
| colima | 192.168.5.1 | 100.64.0.4 |
| jetson-desktop | 192.168.1.6 | 100.64.0.7 |

## Fichiers

- `README.md` — Ce fichier (documentation + commandes SSH)

## Différence avec le cluster PRD

En PRD (`contabo-prd`), les VMs Contabo n'ont pas de NAT/bridge, donc `--node-ip` suffit.
En dev, `colima` est derrière un bridge (192.168.5.0/24) et `jetson-desktop` est sur le LAN
(192.168.1.0/24), donc `--flannel-iface=tailscale0` est impératif pour forcer VXLAN sur le VPN.

## Références

- [Flannel VXLAN docs](https://flannel-io.github.io/documentation/#vxlan)
- [K3s networking docs](https://docs.k3s.io/networking/basic-network-options)
- [etcd member update](https://etcd.io/docs/v3.5/op-guide/runtime-configuration/#update-a-member)
- Issue historique : PostgreSQL timeouts via DERP relay (README.md § "PostgreSQL : performances dégradées via NFS over Tailscale DERP")
