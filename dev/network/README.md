# Dev Cluster Tailscale Networking Fix

Ce dossier contient les manifests Flux pour sécuriser la configuration Flannel/Tailscale du cluster dev.

## Problème constaté

Le cluster dev utilise `--node-external-ip` et `--node-ip` pointant vers les IPs Tailscale,
mais **Flannel n'est pas configuré pour utiliser `tailscale0` comme interface VXLAN**.
Résultat :
- `flannel.alpha.coreos.com/public-ip` pointe vers les IPs LAN (192.168.x.x / 192.168.5.1)
- lenovo (control plane) n'a même pas `--node-ip` — son INTERNAL-IP est `192.168.1.4`
- Le VXLAN overlay passe par le réseau local au lieu de Tailscale

## Fix appliqué (via Flux)

1. **Annotations `flannel.alpha.coreos.com/public-ip-overwrite`** sur tous les nodes ✅
2. **Job `flannel-annotation-refresh`** qui reapplique ces annotations si on re-crée un node
3. **Kustomization** dans `config/dev/kustomization.yaml` pour que Flux reconcile

## Fix PERSISTANT requis sur chaque node physique

Ces configurations doivent être appliquées sur **chaque machine physique**. Sans cela,
au redémarrage du node, K3s re-calculera `flannel.alpha.coreos.com/public-ip` en utilisant
l'interface par défaut (eth0/wlan0) et repassera en LAN IP.

### lenovo (control plane)

```bash
ssh ton-user@lenovo

# Vérifier la config actuelle
cat /etc/rancher/k3s/config.yaml

# Ajouter les directives manquantes
sudo mkdir -p /etc/rancher/k3s
sudo tee -a /etc/rancher/k3s/config.yaml <<EOF
node-ip: 100.64.0.6
flannel-iface: tailscale0
EOF

# Redémarrer k3s (control plane)
sudo systemctl restart k3s
```

### colima (VM Mac Mini)

```bash
# Depuis le Mac Mini
ssh docker-user@colima  # ou via `colima ssh`

# Dans la VM Colima :
sudo mkdir -p /etc/rancher/k3s
sudo tee -a /etc/rancher/k3s/config.yaml <<EOF
flannel-iface: tailscale0
EOF

# Redémarrer l'agent
sudo systemctl restart k3s-agent
```

### jetson-desktop 

```bash
ssh ton-user@jetson-desktop

sudo mkdir -p /etc/rancher/k3s
sudo tee -a /etc/rancher/k3s/config.yaml <<EOF
flannel-iface: tailscale0
EOF

sudo systemctl restart k3s-agent
```

## Vérification post-fix

Après le redémarrage de chaque node, vérifier :

```bash
# 1. Tous les nodes doivent avoir INTERNAL-IP = Tailscale IP
kubectl get nodes -o wide

# 2. Flannel public-ip doit être sur Tailscale
for node in lenovo colima jetson-desktop; do
  kubectl get node $node -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{"\n"}'
done

# 3. Les annotations public-ip-overwrite doivent être présentes
kubectl get node lenovo -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip-overwrite}'
# => 100.64.0.6
```

## Différence avec le cluster PRD

En PRD (`contabo-prd`), les VMs Contabo n'ont pas de NAT/bridge, donc `--node-ip` suffit.
En dev, `colima` est derrière un bridge (192.168.5.0/24) et `jetson-desktop` est sur le LAN
(192.168.1.0/24), donc `--flannel-iface=tailscale0` est impératif pour forcer VXLAN sur le VPN.

## Références

- [Flannel VXLAN docs](https://flannel-io.github.io/documentation/#vxlan)
- [K3s networking docs](https://docs.k3s.io/networking/basic-network-options)
- Issue historique : PostgreSQL timeouts via DERP relay (README.md § "PostgreSQL : performances dégradées via NFS over Tailscale DERP")
