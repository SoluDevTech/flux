#!/bin/bash

#===============================================================================
# K3s Cluster Setup Script
# Script pour installer un cluster K3s avec control plane et workers
#===============================================================================

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
DRY_RUN=false
CP_CLUSTER_IP=""

# Associative arrays pour user/pass par machine
declare -A NODE_USER
declare -A NODE_PASS

#===============================================================================
# Fonctions utilitaires
#===============================================================================

print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

Script d'installation de cluster K3s

OPTIONS:
    -c, --control-plane USER:PASS@IP    Control plane (accès SSH)
    -w, --worker USER:PASS@IP           Worker node (répétable)
    --cp-ip IP                          IP du control plane pour le cluster
                                        (Tailscale/Headscale, défaut: IP de -c)
    --dry-run                           Afficher les commandes sans les exécuter
    -h, --help                          Afficher cette aide

COMMANDES:
    init                        Initialiser le control plane
    join                        Joindre les workers au cluster
    status                      Vérifier l'état du cluster
    uninstall                   Désinstaller K3s des nœuds
    get-token                   Récupérer le token de join

EXEMPLES:
    # Initialiser le control plane localement
    $0 init

    # Initialiser sur un serveur distant
    $0 -c pi:pass@192.168.1.10 init

    # Ajouter des workers
    $0 -c pi:pass@192.168.1.10 \
       -w admin:pass@192.168.1.11 \
       -w root:pass@192.168.1.12 \
       join

    # Avec IP Tailscale pour le cluster
    $0 -c pi:pass@192.168.1.10 --cp-ip 100.64.0.1 \
       -w admin:pass@192.168.1.11 \
       join

    # Init + join en une commande
    $0 -c pi:pass@192.168.1.10 \
       -w pi:pass@192.168.1.11 \
       init join

    # Vérifier l'état
    $0 -c pi:pass@192.168.1.10 status

    # Désinstaller
    $0 -c pi:pass@192.168.1.10 \
       -w pi:pass@192.168.1.11 \
       uninstall
EOF
    exit 1
}

#===============================================================================
# Fonctions SSH
#===============================================================================

run_remote() {
    local host=$1
    local cmd=$2
    local user="${NODE_USER[$host]}"
    local pass="${NODE_PASS[$host]}"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY-RUN] Sur $host: $cmd"
        return 0
    fi
    
    local target="$host"
    [ -n "$user" ] && target="${user}@${host}"
    
    if [ -n "$pass" ]; then
        sshpass -p "$pass" ssh -t -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$target" "$cmd"
    else
        ssh -t -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$target" "$cmd"
    fi
}

run_remote_sudo() {
    local host=$1
    local cmd=$2
    local pass="${NODE_PASS[$host]}"
    
    if [ -n "$pass" ]; then
        run_remote "$host" "echo '$pass' | sudo -S bash -c '$cmd'"
    else
        run_remote "$host" "sudo bash -c '$cmd'"
    fi
}

test_connection() {
    local host=$1
    print_info "Test de connexion à $host..."
    
    if run_remote "$host" "echo 'OK'" &>/dev/null; then
        print_success "Connexion à $host OK"
        return 0
    else
        print_error "Impossible de se connecter à $host"
        return 1
    fi
}

is_local() {
    local host=$1
    [ -z "$host" ] || [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ]
}

#===============================================================================
# Installation K3s
#===============================================================================

install_control_plane() {
    local host=$1
    
    print_header "Installation du Control Plane K3s"
    
    if is_local "$host"; then
        print_info "Installation locale du control plane..."
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] curl -sfL https://get.k3s.io | sh -"
        else
            curl -sfL https://get.k3s.io | sh -
        fi
    else
        print_info "Installation du control plane sur $host..."
        test_connection "$host" || exit 1
        run_remote_sudo "$host" "curl -sfL https://get.k3s.io | sh -"
    fi
    
    print_info "Attente du démarrage de K3s..."
    sleep 10
    
    # Vérification
    print_info "Vérification de l'installation..."
    if is_local "$host"; then
        [ "$DRY_RUN" = false ] && sudo k3s kubectl get nodes
    else
        run_remote_sudo "$host" "k3s kubectl get nodes"
    fi
    
    print_success "Control plane installé avec succès!"
    
    # Afficher le token
    echo ""
    print_info "Token de join:"
    if is_local "$host"; then
        [ "$DRY_RUN" = false ] && sudo cat /var/lib/rancher/k3s/server/node-token
    else
        run_remote_sudo "$host" "cat /var/lib/rancher/k3s/server/node-token"
    fi
}

get_join_token() {
    local host=$1
    
    if is_local "$host"; then
        sudo cat /var/lib/rancher/k3s/server/node-token 2>/dev/null
    else
        run_remote_sudo "$host" "cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null
    fi
}

install_worker() {
    local worker_ip=$1
    local cluster_ip=$2
    local token=$3
    
    print_info "Installation du worker sur $worker_ip..."
    print_info "Connexion au cluster via $cluster_ip"
    test_connection "$worker_ip" || return 1
    
    local k3s_cmd="curl -sfL https://get.k3s.io | K3S_URL=https://${cluster_ip}:6443 K3S_TOKEN=${token} sh -"
    
    run_remote_sudo "$worker_ip" "$k3s_cmd"
    
    sleep 5
    run_remote_sudo "$worker_ip" "systemctl status k3s-agent --no-pager" || true
    
    print_success "Worker $worker_ip installé!"
}

install_workers() {
    local control_plane_ip=$1
    local cluster_ip=$2
    shift 2
    local workers=("$@")
    
    print_header "Installation des Workers K3s"
    
    print_info "Récupération du token depuis $control_plane_ip..."
    local token=$(get_join_token "$control_plane_ip")
    
    if [ -z "$token" ]; then
        print_error "Impossible de récupérer le token"
        exit 1
    fi
    print_success "Token récupéré"
    
    for worker in "${workers[@]}"; do
        echo ""
        install_worker "$worker" "$cluster_ip" "$token"
    done
    
    # Vérification finale
    print_header "Vérification du Cluster"
    sleep 5
    
    if is_local "$control_plane_ip"; then
        sudo k3s kubectl get nodes -o wide
    else
        run_remote_sudo "$control_plane_ip" "k3s kubectl get nodes -o wide"
    fi
}

#===============================================================================
# Gestion du cluster
#===============================================================================

check_status() {
    local host=$1
    
    print_header "État du Cluster"
    
    print_info "Service K3s:"
    if is_local "$host"; then
        sudo systemctl status k3s --no-pager || true
    else
        run_remote_sudo "$host" "systemctl status k3s --no-pager" || true
    fi
    
    echo ""
    print_info "Nœuds:"
    if is_local "$host"; then
        sudo k3s kubectl get nodes -o wide
    else
        run_remote_sudo "$host" "k3s kubectl get nodes -o wide"
    fi
    
    echo ""
    print_info "Pods système:"
    if is_local "$host"; then
        sudo k3s kubectl get pods -A
    else
        run_remote_sudo "$host" "k3s kubectl get pods -A"
    fi
}

uninstall_node() {
    local host=$1
    local is_server=$2
    
    print_info "Désinstallation de K3s sur $host..."
    
    local script="/usr/local/bin/k3s-agent-uninstall.sh"
    [ "$is_server" = true ] && script="/usr/local/bin/k3s-uninstall.sh"
    
    if is_local "$host"; then
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY-RUN] $script"
        else
            sudo $script || print_warning "Script non trouvé sur $host"
        fi
    else
        run_remote_sudo "$host" "$script" || print_warning "Script non trouvé sur $host"
    fi
    
    print_success "K3s désinstallé de $host"
}

uninstall_cluster() {
    local control_plane_ip=$1
    shift
    local workers=("$@")
    
    print_header "Désinstallation du Cluster K3s"
    
    print_warning "Ceci va supprimer K3s de tous les nœuds!"
    read -p "Continuer? (o/N) " -n 1 -r
    echo
    
    [[ ! $REPLY =~ ^[Oo]$ ]] && { print_info "Annulé"; exit 0; }
    
    # Workers d'abord
    for worker in "${workers[@]}"; do
        uninstall_node "$worker" false
    done
    
    # Puis control plane
    uninstall_node "$control_plane_ip" true
    
    print_success "Cluster désinstallé!"
}

#===============================================================================
# Main
#===============================================================================

CONTROL_PLANE_IP=""
WORKERS=()
COMMANDS=""

# Fonction pour parser user:pass@ip
parse_node_spec() {
    local spec="$1"
    local user_pass="${spec%@*}"
    local ip="${spec##*@}"
    local user="${user_pass%:*}"
    local pass="${user_pass#*:}"
    NODE_USER[$ip]="$user"
    NODE_PASS[$ip]="$pass"
    echo "$ip"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--control-plane)
            CONTROL_PLANE_IP=$(parse_node_spec "$2")
            shift 2
            ;;
        -w|--worker)
            worker_ip=$(parse_node_spec "$2")
            WORKERS+=("$worker_ip")
            shift 2
            ;;
        --cp-ip)
            CP_CLUSTER_IP="$2"
            shift 2
            ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        init|join|status|uninstall|get-token) COMMANDS="$COMMANDS $1"; shift ;;
        *) print_error "Option inconnue: $1"; usage ;;
    esac
done

[ -z "$COMMANDS" ] && { print_error "Aucune commande spécifiée"; usage; }

# Si --cp-ip non spécifié, utiliser l'IP SSH du control plane
[ -z "$CP_CLUSTER_IP" ] && CP_CLUSTER_IP="$CONTROL_PLANE_IP"

for cmd in $COMMANDS; do
    case $cmd in
        init)
            install_control_plane "$CONTROL_PLANE_IP"
            ;;
        join)
            [ ${#WORKERS[@]} -eq 0 ] && { print_error "Aucun worker spécifié (-w)"; exit 1; }
            install_workers "$CONTROL_PLANE_IP" "$CP_CLUSTER_IP" "${WORKERS[@]}"
            ;;
        status)
            check_status "$CONTROL_PLANE_IP"
            ;;
        uninstall)
            uninstall_cluster "$CONTROL_PLANE_IP" "${WORKERS[@]}"
            ;;
        get-token)
            print_header "Token K3s"
            token=$(get_join_token "$CONTROL_PLANE_IP")
            [ -n "$token" ] && echo "$token" || { print_error "Échec"; exit 1; }
            ;;
    esac
done

print_success "Terminé!"