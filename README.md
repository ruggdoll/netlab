# NetLab

Station d'analyse réseau pour la recherche en sécurité. Transforme un poste Linux en point d'accès WiFi avec interception SSL transparente.

## Cas d'usage

- Analyse du trafic d'appareils IoT (prises connectées, caméras, etc.)
- Reverse engineering de protocoles d'applications mobiles
- Audit de sécurité d'équipements embarqués
- Recherche sur les communications chiffrées

## Architecture

```
                                    ┌─────────────────────────────────────┐
                                    │          Poste Linux                │
                                    │                                     │
[Internet] ◄───► [wlan0/WAN] ◄────► │  iptables ───► mitmproxy (:8080)   │
                                    │      │                              │
                                    │      ▼                              │
                                    │   Wireshark                         │
                                    └──────────────┬──────────────────────┘
                                                   │
                                            [wlan1/AP]
                                                   │
                              ┌────────────────────┼────────────────────┐
                              │                    │                    │
                              ▼                    ▼                    ▼
                         [iPhone]           [Prise IoT]          [Autre device]
```

## Prérequis

```bash
sudo apt install hostapd dnsmasq iptables iw tcpdump mitmproxy
```

Matériel :
- 2 interfaces WiFi (une pour Internet, une pour l'AP)
- Un adaptateur USB WiFi fonctionne parfaitement pour l'AP

## Installation

```bash
git clone https://github.com/votre-user/netlab.git
cd netlab
chmod +x netlab.sh
```

Éditez les variables en haut de `netlab.sh` selon vos interfaces :

```bash
IFACE_WAN="wlp2s0"           # Interface connectée à Internet
IFACE_AP="wlx00c0cab68fbb"   # Interface pour le point d'accès
AP_SSID="NetLab-Analysis"
AP_PASSWORD="SecureLabPass2024"
```

## Utilisation

### Commandes

| Commande | Description |
|----------|-------------|
| `sudo ./netlab.sh start` | Démarre le lab (AP + routage + redirection) |
| `sudo ./netlab.sh stop` | Arrête tout et restaure le système |
| `sudo ./netlab.sh status` | Affiche l'état actuel |
| `sudo ./netlab.sh clients` | Liste les appareils connectés |
| `sudo ./netlab.sh capture` | Lance une capture pcap |
| `sudo ./netlab.sh watch` | Affiche le trafic en direct |

### Workflow typique

```bash
# 1. Démarrer le lab
sudo ./netlab.sh start

# 2. Lancer mitmproxy (dans un autre terminal)
mitmproxy --mode transparent --listen-host 0.0.0.0 --listen-port 8080

# 3. Connecter les appareils au WiFi "NetLab-Analysis"

# 4. Identifier les appareils
sudo ./netlab.sh clients

# 5. Analyser dans Wireshark avec filtre: ip.addr == <IP_APPAREIL>

# 6. Terminer
sudo ./netlab.sh stop
```

## Installation du certificat mitmproxy

Pour intercepter le trafic HTTPS, les appareils doivent faire confiance au CA de mitmproxy.

### Servir le certificat

```bash
# Le CA est généré au premier lancement de mitmproxy
mitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080

# Servir le certificat via HTTP (dans un autre terminal)
cd ~/.mitmproxy
python3 -m http.server 8888 --bind 10.66.66.1
```

### Sur iPhone

1. Connectez-vous au WiFi **NetLab-Analysis**
2. Ouvrez Safari : `http://10.66.66.1:8888/mitmproxy-ca-cert.pem`
3. **Autoriser** le téléchargement du profil
4. **Réglages → Profil téléchargé → Installer**
5. **Réglages → Général → Informations → Réglages des certificats**
   → Activer la confiance pour **mitmproxy**

### Sur Android

1. Téléchargez le certificat via le navigateur
2. **Paramètres → Sécurité → Installer un certificat → Certificat CA**

### Vérification

Ouvrez `https://example.com` dans Safari/Chrome. Si la requête apparaît dans mitmproxy, l'interception fonctionne.

## Proxy transparent

Le proxy est **réellement transparent** : aucune configuration n'est nécessaire sur les appareils (pas de proxy manuel).

```
Appareil → HTTPS (port 443) → AP → iptables REDIRECT → mitmproxy (port 8080)
```

L'appareil croit communiquer directement avec le serveur distant. iptables intercepte et redirige silencieusement vers mitmproxy.

## Notes sur l'IoT

Les appareils IoT peuvent utiliser :

| Protocole | Port | Chiffré | Notes |
|-----------|------|---------|-------|
| HTTP | 80 | Non | Interceptable directement |
| HTTPS | 443 | Oui | Nécessite le certificat CA |
| MQTT | 1883 | Non | Très courant en IoT |
| MQTTS | 8883 | Oui | MQTT sur TLS |
| CoAP | 5683 | Non | UDP, léger |

### Certificate pinning

Certains appareils implémentent du **certificate pinning** et refuseront les connexions même avec le CA installé. Dans ce cas :

- Analysez le trafic **DNS** (révèle les serveurs contactés)
- Cherchez du trafic **non chiffré** (HTTP, MQTT)
- Utilisez Wireshark pour analyser les **métadonnées** TLS (SNI, certificats)

## Nommer les appareils

Éditez `DEVICE_NAMES` dans le script pour identifier facilement les appareils :

```bash
declare -A DEVICE_NAMES=(
    ["aa:bb:cc:dd:ee:ff"]="iPhone"
    ["11:22:33:44:55:66"]="Prise-IoT"
)
```

La commande `clients` affichera alors les noms au lieu des MAC.

## Wireshark

### Filtres utiles

```
# Trafic d'un appareil spécifique
ip.addr == 10.66.66.101

# Requêtes DNS
dns

# Trafic MQTT
mqtt

# Trafic HTTP
http

# Handshakes TLS (voir SNI)
tls.handshake.type == 1
```

### Déchiffrement TLS

Pour déchiffrer le trafic dans Wireshark avec votre certificat :

1. **Edit → Preferences → Protocols → TLS**
2. **RSA keys list → Edit**
3. Ajoutez votre clé privée

## Sécurité

- Le script ne modifie aucun fichier système de manière permanente
- Tout est restauré à l'arrêt (`stop`)
- Les fichiers temporaires sont dans `/tmp/netlab/`
- Aucun service n'est activé au démarrage

## Licence

MIT
