#!/bin/bash
#
# NetLab - Station d'analyse réseau pour recherche en sécurité
# Transforme le poste en AP avec interception SSL transparente
#
# Usage: ./netlab.sh start|stop|status
#

set -e

# ============================================================================
# CONFIGURATION - Adapter selon votre environnement
# ============================================================================

# Interface connectée à Internet (uplink)
IFACE_WAN="wlp2s0"

# Interface pour le point d'accès (AP) - adaptateur USB
IFACE_AP="wlx00c0cab68fbb"

# Configuration du point d'accès
AP_SSID="NetLab-Analysis"
AP_PASSWORD="123VivaLaSSI"
AP_CHANNEL="6"

# Réseau du lab
AP_IP="10.66.66.1"
AP_NETMASK="255.255.255.0"
AP_NETWORK="10.66.66.0/24"
DHCP_RANGE_START="10.66.66.100"
DHCP_RANGE_END="10.66.66.200"
DHCP_LEASE="12h"

# Port du proxy d'interception (mitmproxy en mode transparent)
PROXY_PORT="8080"

# Mapping des appareils (MAC -> Nom lisible)
# Remplis après le premier 'clients' pour identifier facilement dans Wireshark
declare -A DEVICE_NAMES=(
    # ["aa:bb:cc:dd:ee:ff"]="Telephone"
    # ["11:22:33:44:55:66"]="Prise-IoT"
)

# Fichiers temporaires (nettoyés au stop)
RUNTIME_DIR="/tmp/netlab"
HOSTAPD_CONF="$RUNTIME_DIR/hostapd.conf"
DNSMASQ_CONF="$RUNTIME_DIR/dnsmasq.conf"
DNSMASQ_PID="$RUNTIME_DIR/dnsmasq.pid"
HOSTAPD_PID="$RUNTIME_DIR/hostapd.pid"
IPTABLES_BACKUP="$RUNTIME_DIR/iptables.backup"
STATE_FILE="$RUNTIME_DIR/netlab.state"

# ============================================================================
# FONCTIONS UTILITAIRES
# ============================================================================

log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m[OK]\033[0m $1"
}

log_error() {
    echo -e "\033[1;31m[ERREUR]\033[0m $1" >&2
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ce script doit être exécuté en root (sudo)"
        exit 1
    fi
}

check_dependencies() {
    local missing=()

    for cmd in hostapd dnsmasq iptables ip iw tcpdump; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dépendances manquantes: ${missing[*]}"
        log_info "Installation: sudo apt install hostapd dnsmasq iptables iw tcpdump"
        exit 1
    fi
}

check_interfaces() {
    if ! ip link show "$IFACE_WAN" &>/dev/null; then
        log_error "Interface WAN '$IFACE_WAN' non trouvée"
        log_info "Interfaces disponibles:"
        ip -br link show | grep -E "^wl"
        exit 1
    fi

    if ! ip link show "$IFACE_AP" &>/dev/null; then
        log_error "Interface AP '$IFACE_AP' non trouvée"
        log_info "Interfaces disponibles:"
        ip -br link show | grep -E "^wl"
        exit 1
    fi
}

is_running() {
    [[ -f "$STATE_FILE" ]]
}

# ============================================================================
# FONCTIONS DE DÉMARRAGE
# ============================================================================

save_state() {
    mkdir -p "$RUNTIME_DIR"

    # Sauvegarder l'état actuel du forwarding IP
    cat /proc/sys/net/ipv4/ip_forward > "$RUNTIME_DIR/ip_forward.backup"

    # Sauvegarder les règles iptables
    iptables-save > "$IPTABLES_BACKUP"

    # Sauvegarder l'état de l'interface AP
    ip addr show "$IFACE_AP" > "$RUNTIME_DIR/iface_ap.backup" 2>/dev/null || true

    log_success "État système sauvegardé"
}

setup_ap_interface() {
    log_info "Configuration de l'interface AP..."

    # Tuer les processus qui pourraient verrouiller l'interface
    pkill -9 -f "hostapd" 2>/dev/null || true
    pkill -9 -f "wpa_supplicant.*$IFACE_AP" 2>/dev/null || true
    sleep 2

    # Arrêter NetworkManager d'abord pour libérer l'interface
    systemctl stop NetworkManager 2>/dev/null || true
    sleep 1

    # Débloquer le WiFi si bloqué par rfkill
    rfkill unblock wifi 2>/dev/null || true

    # Réinitialiser complètement l'interface
    ip link set "$IFACE_AP" down 2>/dev/null || true
    sleep 1
    iw dev "$IFACE_AP" set type managed 2>/dev/null || true
    sleep 2

    # Redémarrer NetworkManager mais exclure l'interface AP
    if [[ -d /etc/NetworkManager ]]; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/netlab-exclude.conf << EOF
[keyfile]
unmanaged-devices=interface-name:$IFACE_AP
EOF
        systemctl start NetworkManager 2>/dev/null || true
        sleep 2
    fi

    # Configurer l'interface AP
    ip link set "$IFACE_AP" down 2>/dev/null || true
    ip addr flush dev "$IFACE_AP" 2>/dev/null || true
    sleep 1
    ip addr add "$AP_IP/24" dev "$IFACE_AP"
    ip link set "$IFACE_AP" up

    log_success "Interface AP configurée: $IFACE_AP ($AP_IP)"
}

create_hostapd_conf() {
    cat > "$HOSTAPD_CONF" << EOF
interface=$IFACE_AP
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=$AP_CHANNEL
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF
    log_success "Configuration hostapd créée"
}

create_dnsmasq_conf() {
    cat > "$DNSMASQ_CONF" << EOF
interface=$IFACE_AP
listen-address=$AP_IP
bind-dynamic
except-interface=lo
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$AP_NETMASK,$DHCP_LEASE
dhcp-option=option:router,$AP_IP
dhcp-option=option:dns-server,$AP_IP
log-queries
log-dhcp
EOF
    log_success "Configuration dnsmasq créée"
}

start_hostapd() {
    log_info "Démarrage de hostapd..."
    hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF"
    sleep 2

    if [[ -f "$HOSTAPD_PID" ]] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
        log_success "hostapd démarré (SSID: $AP_SSID)"
    else
        log_error "Échec du démarrage de hostapd"
        cat "$RUNTIME_DIR/hostapd.log" 2>/dev/null || true
        exit 1
    fi
}

start_dnsmasq() {
    log_info "Démarrage de dnsmasq..."

    # S'assurer qu'aucun dnsmasq n'utilise déjà l'interface
    pkill -f "dnsmasq.*$IFACE_AP" 2>/dev/null || true
    sleep 1

    dnsmasq -C "$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID"
    sleep 1

    if [[ -f "$DNSMASQ_PID" ]] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
        log_success "dnsmasq démarré (DHCP: $DHCP_RANGE_START - $DHCP_RANGE_END)"
    else
        log_error "Échec du démarrage de dnsmasq"
        exit 1
    fi
}

setup_routing() {
    log_info "Configuration du routage et NAT..."

    # Activer le forwarding IP
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Règles iptables pour NAT et redirection transparente
    # NAT pour le trafic sortant
    iptables -t nat -A POSTROUTING -s "$AP_NETWORK" -o "$IFACE_WAN" -j MASQUERADE

    # Redirection transparente HTTP + HTTPS -> proxy (même port)
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp --dport 80 -j REDIRECT --to-port "$PROXY_PORT"
    iptables -t nat -A PREROUTING -i "$IFACE_AP" -p tcp --dport 443 -j REDIRECT --to-port "$PROXY_PORT"

    # Autoriser le forwarding pour le réseau du lab
    iptables -A FORWARD -i "$IFACE_AP" -o "$IFACE_WAN" -j ACCEPT
    iptables -A FORWARD -i "$IFACE_WAN" -o "$IFACE_AP" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Autoriser le trafic local vers le proxy
    iptables -A INPUT -i "$IFACE_AP" -p tcp --dport "$PROXY_PORT" -j ACCEPT

    log_success "Routage et NAT configurés"
}

create_state_file() {
    cat > "$STATE_FILE" << EOF
STARTED_AT=$(date -Iseconds)
IFACE_WAN=$IFACE_WAN
IFACE_AP=$IFACE_AP
AP_SSID=$AP_SSID
AP_IP=$AP_IP
PROXY_PORT=$PROXY_PORT
EOF
}

# ============================================================================
# FONCTIONS D'ARRÊT
# ============================================================================

stop_services() {
    log_info "Arrêt des services..."

    # Arrêter hostapd
    if [[ -f "$HOSTAPD_PID" ]]; then
        kill "$(cat "$HOSTAPD_PID")" 2>/dev/null || true
        rm -f "$HOSTAPD_PID"
        log_success "hostapd arrêté"
    fi

    # Arrêter dnsmasq
    if [[ -f "$DNSMASQ_PID" ]]; then
        kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
        log_success "dnsmasq arrêté"
    fi

    # Arrêter tout dnsmasq lié à notre interface
    pkill -f "dnsmasq.*$IFACE_AP" 2>/dev/null || true
}

restore_state() {
    log_info "Restauration de l'état système..."

    # Restaurer les règles iptables
    if [[ -f "$IPTABLES_BACKUP" ]]; then
        iptables-restore < "$IPTABLES_BACKUP"
        log_success "Règles iptables restaurées"
    fi

    # Restaurer le forwarding IP
    if [[ -f "$RUNTIME_DIR/ip_forward.backup" ]]; then
        cat "$RUNTIME_DIR/ip_forward.backup" > /proc/sys/net/ipv4/ip_forward
        log_success "IP forwarding restauré"
    fi

    # Réinitialiser l'interface AP
    ip addr flush dev "$IFACE_AP" 2>/dev/null || true
    ip link set "$IFACE_AP" down 2>/dev/null || true
    iw dev "$IFACE_AP" set type managed 2>/dev/null || true

    # Supprimer l'exclusion NetworkManager
    rm -f /etc/NetworkManager/conf.d/netlab-exclude.conf 2>/dev/null || true

    # Redémarrer NetworkManager pour reprendre le contrôle
    systemctl restart NetworkManager 2>/dev/null || true

    log_success "Interface AP réinitialisée"
}

cleanup_runtime() {
    rm -rf "$RUNTIME_DIR"
    log_success "Fichiers temporaires nettoyés"
}

# ============================================================================
# COMMANDES PRINCIPALES
# ============================================================================

do_start() {
    log_info "=========================================="
    log_info "  NetLab - Démarrage du laboratoire"
    log_info "=========================================="

    if is_running; then
        log_error "NetLab est déjà en cours d'exécution"
        log_info "Utilisez '$0 stop' pour l'arrêter d'abord"
        exit 1
    fi

    check_dependencies
    check_interfaces

    save_state
    setup_ap_interface
    create_hostapd_conf
    create_dnsmasq_conf
    start_hostapd
    start_dnsmasq
    setup_routing
    create_state_file

    echo ""
    log_success "=========================================="
    log_success "  NetLab est opérationnel!"
    log_success "=========================================="
    echo ""
    log_info "Point d'accès WiFi:"
    log_info "  SSID:     $AP_SSID"
    log_info "  Password: $AP_PASSWORD"
    log_info "  Gateway:  $AP_IP"
    echo ""
    log_info "Interception transparente:"
    log_info "  HTTP + HTTPS redirigés vers: localhost:$PROXY_PORT"
    echo ""
    log_warn "N'oubliez pas de démarrer mitmproxy!"
    log_info "  mitmproxy --mode transparent --listen-host 0.0.0.0 --listen-port $PROXY_PORT"
    log_info "  # ou avec interface web:"
    log_info "  mitmweb --mode transparent --listen-host 0.0.0.0 --listen-port $PROXY_PORT --web-host 0.0.0.0"
    echo ""
    log_info "Pour Wireshark, configurez la clé privée dans:"
    log_info "  Edit > Preferences > Protocols > TLS > RSA keys list"
    echo ""
    echo ""
    echo -e "\033[1;36m┌──────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;36m│                      WORKFLOW TYPIQUE                            │\033[0m"
    echo -e "\033[1;36m├──────────────────────────────────────────────────────────────────┤\033[0m"
    echo -e "\033[1;36m│\033[0m 1. \033[1;32m✓ FAIT\033[0m - AP \"$AP_SSID\" créé                       \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m 2. Lance mitmproxy :                                            \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m    \033[1;33mmitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080\033[0m   \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m 3. Connecte téléphone + prise IoT au WiFi \"$AP_SSID\"    \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m 4. \033[1;33msudo $0 clients\033[0m → récupère les IP              \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m    puis édite DEVICE_NAMES dans le script pour les nommer      \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m 5. Ouvre Wireshark sur \033[1;33m$IFACE_AP\033[0m                    \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m    avec filtre: \033[1;33mip.addr == <IP_PRISE>\033[0m                         \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m 6. Analyse terminée → \033[1;33msudo $0 stop\033[0m                 \033[1;36m│\033[0m"
    echo -e "\033[1;36m├──────────────────────────────────────────────────────────────────┤\033[0m"
    echo -e "\033[1;36m│\033[0m \033[1;35mNote IoT:\033[0m Les prises connectées utilisent souvent du         \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m certificate pinning ou des protocoles non-HTTP.                \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m Si l'interception SSL échoue, analyse:                         \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m   • \033[1;33mDNS\033[0m      - révèle les serveurs contactés                  \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m   • \033[1;33mHTTP\033[0m     - beaucoup d'IoT cheap n'utilisent pas TLS       \033[1;36m│\033[0m"
    echo -e "\033[1;36m│\033[0m   • \033[1;33mMQTT\033[0m     - port 1883 (clair) / 8883 (chiffré)             \033[1;36m│\033[0m"
    echo -e "\033[1;36m└──────────────────────────────────────────────────────────────────┘\033[0m"
    echo ""
}

do_stop() {
    log_info "=========================================="
    log_info "  NetLab - Arrêt du laboratoire"
    log_info "=========================================="

    if ! is_running; then
        log_warn "NetLab n'est pas en cours d'exécution"
        # Nettoyage de sécurité quand même
        cleanup_runtime 2>/dev/null || true
        exit 0
    fi

    stop_services
    restore_state
    cleanup_runtime

    echo ""
    log_success "=========================================="
    log_success "  NetLab arrêté - Système restauré"
    log_success "=========================================="
    echo ""
}

do_status() {
    echo ""
    if is_running; then
        log_success "NetLab est EN COURS D'EXÉCUTION"
        echo ""
        if [[ -f "$STATE_FILE" ]]; then
            source "$STATE_FILE"
            log_info "Démarré à: $STARTED_AT"
            log_info "Interface WAN: $IFACE_WAN"
            log_info "Interface AP:  $IFACE_AP"
            log_info "SSID:          $AP_SSID"
            log_info "Gateway:       $AP_IP"
        fi
        echo ""
        log_info "Processus:"
        if [[ -f "$HOSTAPD_PID" ]]; then
            echo "  hostapd: PID $(cat "$HOSTAPD_PID")"
        fi
        if [[ -f "$DNSMASQ_PID" ]]; then
            echo "  dnsmasq: PID $(cat "$DNSMASQ_PID")"
        fi
    else
        log_info "NetLab est ARRÊTÉ"
    fi
    echo ""
}

do_clients() {
    if ! is_running; then
        log_error "NetLab n'est pas démarré"
        exit 1
    fi

    echo ""
    log_info "=========================================="
    log_info "  Clients connectés au lab"
    log_info "=========================================="
    echo ""

    # Récupérer les clients via les baux DHCP de dnsmasq
    printf "%-18s  %-15s  %-20s\n" "MAC" "IP" "NOM"
    printf "%-18s  %-15s  %-20s\n" "------------------" "---------------" "--------------------"

    # Fichier de baux dnsmasq (format: timestamp mac ip hostname client-id)
    local leases_file="/var/lib/misc/dnsmasq.leases"

    if [[ -f "$leases_file" ]]; then
        while read -r _ts mac ip hostname _cid; do
            if [[ -n "$mac" && -n "$ip" ]]; then
                # Chercher le nom dans le mapping, sinon utiliser le hostname DHCP
                name="${DEVICE_NAMES[$mac]:-$hostname}"
                [[ "$name" == "*" || -z "$name" ]] && name="(non identifié)"
                printf "%-18s  %-15s  %-20s\n" "$mac" "$ip" "$name"
            fi
        done < "$leases_file"
    else
        log_warn "Fichier de baux DHCP non trouvé"
    fi

    echo ""
    log_info "Filtres Wireshark par appareil:"
    if [[ -f "$leases_file" ]]; then
        while read -r _ts mac ip hostname _cid; do
            if [[ -n "$mac" && -n "$ip" ]]; then
                name="${DEVICE_NAMES[$mac]:-$hostname}"
                [[ "$name" == "*" || -z "$name" ]] && name="$mac"
                echo "  $name: ip.addr == $ip"
            fi
        done < "$leases_file"
    fi

    echo ""
    log_warn "Pour nommer les appareils, édite DEVICE_NAMES dans le script:"
    log_info "  declare -A DEVICE_NAMES=("
    if [[ -f "$leases_file" ]]; then
        while read -r _ts mac _ip _hostname _cid; do
            if [[ -n "$mac" ]]; then
                echo "      [\"$mac\"]=\"MonAppareil\""
            fi
        done < "$leases_file"
    fi
    log_info "  )"
    echo ""
}

do_capture() {
    if ! is_running; then
        log_error "NetLab n'est pas démarré"
        exit 1
    fi

    local output_file="${2:-$RUNTIME_DIR/capture_$(date +%Y%m%d_%H%M%S).pcap}"

    log_info "=========================================="
    log_info "  Capture réseau"
    log_info "=========================================="
    echo ""
    log_info "Fichier: $output_file"
    log_info "Interface: $IFACE_AP"
    log_info "Ctrl+C pour arrêter la capture"
    echo ""

    # Capture sur l'interface AP
    tcpdump -i "$IFACE_AP" -w "$output_file" -v

    echo ""
    log_success "Capture sauvegardée: $output_file"
    log_info "Ouvrir dans Wireshark: wireshark $output_file"
}

do_watch() {
    if ! is_running; then
        log_error "NetLab n'est pas démarré"
        exit 1
    fi

    log_info "=========================================="
    log_info "  Surveillance trafic en direct"
    log_info "=========================================="
    echo ""
    log_info "Interface: $IFACE_AP"
    log_info "Ctrl+C pour arrêter"
    echo ""

    # Afficher le trafic en direct avec tcpdump
    tcpdump -i "$IFACE_AP" -l -n -q
}

show_usage() {
    echo "Usage: $0 {start|stop|status|clients|capture|watch}"
    echo ""
    echo "Commandes:"
    echo "  start    - Démarrer le laboratoire d'analyse réseau"
    echo "  stop     - Arrêter et restaurer le système"
    echo "  status   - Afficher l'état actuel"
    echo "  clients  - Lister les appareils connectés (tel, IoT...)"
    echo "  capture  - Lancer une capture pcap (pour Wireshark)"
    echo "  watch    - Voir le trafic en direct dans le terminal"
    echo ""
    echo "Configuration (modifier en haut du script):"
    echo "  IFACE_WAN  = $IFACE_WAN (interface Internet)"
    echo "  IFACE_AP   = $IFACE_AP (interface point d'accès)"
    echo "  AP_SSID    = $AP_SSID"
    echo ""
}

# ============================================================================
# POINT D'ENTRÉE
# ============================================================================

check_root

case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    status)
        do_status
        ;;
    clients)
        do_clients
        ;;
    capture)
        do_capture "$@"
        ;;
    watch)
        do_watch
        ;;
    *)
        show_usage
        exit 1
        ;;
esac

exit 0
