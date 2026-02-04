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
AP_PASSWORD="VivaLaSSI"
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

# 2. Lancer mitmproxy avec export des clés de session TLS (dans un autre terminal)
SSLKEYLOGFILE=/tmp/netlab/sslkeys.log mitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080

# 3. Connecter les appareils au WiFi "NetLab-Analysis"

# 4. Identifier les appareils
sudo ./netlab.sh clients

# 5. Lancer Wireshark sur l'interface AP (dans un autre terminal)
sudo wireshark -i wlx00c0cab68fbb -k

# 6. Configurer le déchiffrement TLS dans Wireshark (voir section Wireshark)

# 7. Terminer
sudo ./netlab.sh stop
```

## Certificats

Pour intercepter le trafic HTTPS, les appareils doivent faire confiance à l'autorité de certification (AC) utilisée par mitmproxy. Deux options : utiliser l'AC par défaut de mitmproxy, ou générer la vôtre.

> **Ne jamais distribuer la clé privée.** Seul le **certificat public** (`mitmproxy-ca-cert.pem`) doit être installé sur les appareils. La clé privée (`mitmproxy-ca.pem`, `.key`) reste exclusivement sur le poste d'analyse — c'est elle qui permet à mitmproxy de signer les certificats à la volée.

### Option 1 : AC par défaut de mitmproxy

L'AC est générée automatiquement au premier lancement :

```bash
mitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080
```

Les fichiers sont créés dans `~/.mitmproxy/`. Le certificat à distribuer est `mitmproxy-ca-cert.pem` (certificat public uniquement).

### Option 2 : générer sa propre AC

Créez un dossier dédié :

```bash
mkdir -p ~/.mitmproxy-custom
```

Générez la clé privée et le certificat :

```bash
# Clé privée (reste sur le poste, ne jamais distribuer)
openssl genrsa -out ~/.mitmproxy-custom/mitmproxy-ca.key 4096

# Certificat AC avec vos informations
openssl req -new -x509 -key ~/.mitmproxy-custom/mitmproxy-ca.key \
      -out ~/.mitmproxy-custom/mitmproxy-ca.crt \
      -days 1825 \
      -subj "/CN=NetLab CA/O=Mon Labo/OU=Analyse Reseau/L=MaVille/C=FR"
```

Champs personnalisables : `CN` (nom affiché), `O` (organisation), `OU` (unité), `L` (ville), `C` (pays).

Préparez les fichiers pour mitmproxy et pour la distribution :

```bash
# Fichier combiné clé + certificat pour mitmproxy (ne jamais distribuer)
cat ~/.mitmproxy-custom/mitmproxy-ca.key ~/.mitmproxy-custom/mitmproxy-ca.crt \
    > ~/.mitmproxy-custom/mitmproxy-ca.pem

# Certificat seul pour distribution aux appareils (sans clé privée)
cp ~/.mitmproxy-custom/mitmproxy-ca.crt ~/.mitmproxy-custom/mitmproxy-ca-cert.pem
```

Lancez mitmproxy avec votre AC :

```bash
mitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080 --set confdir=~/.mitmproxy-custom
```

Pour vérifier votre certificat :

```bash
openssl x509 -in ~/.mitmproxy-custom/mitmproxy-ca.crt -noout -subject -issuer
```

### Distribuer le certificat aux appareils

Servez **uniquement le certificat public** via HTTP. Ne jamais exposer le répertoire contenant la clé privée :

```bash
mkdir -p /tmp/netlab-cert

# AC par défaut :
cp ~/.mitmproxy/mitmproxy-ca-cert.pem /tmp/netlab-cert/

# Ou AC personnalisée :
# cp ~/.mitmproxy-custom/mitmproxy-ca-cert.pem /tmp/netlab-cert/

# Servir uniquement ce fichier
python3 -m http.server 8888 --bind 10.66.66.1 --directory /tmp/netlab-cert
```

### Installation sur iPhone

1. Connectez-vous au WiFi **NetLab-Analysis**
2. Ouvrez Safari : `http://10.66.66.1:8888/mitmproxy-ca-cert.pem`
3. **Autoriser** le téléchargement du profil
4. **Réglages → Profil téléchargé → Installer**
5. **Réglages → Général → Informations → Réglages des certificats**
   → Activer la confiance totale pour le certificat

### Installation sur Android

1. Ouvrez le navigateur : `http://10.66.66.1:8888/mitmproxy-ca-cert.pem`
2. **Paramètres → Sécurité → Installer un certificat → Certificat CA**

### Suppression du certificat (iPhone)

1. **Réglages → Général → VPN et gestion de l'appareil**
2. Appuyez sur le profil sous **Profil de configuration**
3. **Supprimer le profil** (en rouge en bas)
4. Confirmez avec votre code

La confiance est automatiquement révoquée à la suppression du profil.

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

### Capture

Lancez Wireshark sur l'interface AP pour capturer le trafic des appareils connectés :

```bash
sudo wireshark -i wlx00c0cab68fbb -k
```

Ou via la commande intégrée pour une capture pcap :

```bash
sudo ./netlab.sh capture
```

### Déchiffrement TLS

Le TLS moderne utilise l'échange de clés ECDHE (forward secrecy). La clé privée de l'AC ne suffit pas à déchiffrer le trafic. Il faut exporter les clés de session via `SSLKEYLOGFILE`.

Lancez mitmproxy avec l'export des clés :

```bash
mkdir -p /tmp/netlab-cert
SSLKEYLOGFILE=/tmp/netlab-cert/sslkeys.log mitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080
```
Ou avec votre AC :

```bash
mkdir -p /tmp/netlab-cert
SSLKEYLOGFILE=/tmp/netlab-cert/sslkeys.log mitmproxy --mode transparent --listen-host 0.0.0.0 -p 8080 --set confdir=~/.mitmproxy-custom
```

Puis dans Wireshark :

1. **Edit → Preferences → Protocols → TLS**
2. **(Pre)-Master-Secret log filename** → `/tmp/netlab/sslkeys.log`

Le trafic TLS est déchiffré en temps réel dans la capture.

### Filtres utiles

```
# Trafic d'un appareil spécifique
ip.addr == 10.66.66.101

# Requêtes DNS
dns

# Trafic MQTT
mqtt

# Trafic HTTP déchiffré
http

# Handshakes TLS (voir SNI)
tls.handshake.type == 1
```

## Sécurité

- Le script ne modifie aucun fichier système de manière permanente
- Tout est restauré à l'arrêt (`stop`)
- Les fichiers temporaires sont dans `/tmp/netlab/`
- Aucun service n'est activé au démarrage

## Licence

MIT
