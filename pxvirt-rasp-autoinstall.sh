#!/bin/bash
# =============================================================================
# PXVIRT Installation Script for Raspberry Pi 5
# Compatible: Debian 12 Bookworm / Raspberry Pi OS (Bookworm 64-bit)
# Docs: https://docs.pxvirt.lierfang.com/en/installfromdebian.html
# =============================================================================

set -euo pipefail

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Ce script doit être exécuté en root (sudo ./pxvirtpreps.sh)"
    exit 1
fi

echo "============================================="
echo " PXVIRT - Script d'installation (Pi 5)"
echo "============================================="

# =============================================================================
# 1. HOSTNAME
# =============================================================================
echo ""
echo "[1/6] Configuration du hostname..."

# Récupère l'IP principale (interface UP, hors loopback)
IP_ADDR=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)

if [[ -z "$IP_ADDR" ]]; then
    IP_ADDR=$(hostname -I | awk '{print $1}')
fi

if [[ -z "$IP_ADDR" ]]; then
    echo "[ERROR] Impossible de détecter l'adresse IP."
    exit 1
fi

HOSTNAME_CURRENT=$(hostname -s)
echo "  IP détectée   : $IP_ADDR"
echo "  Hostname actuel : $HOSTNAME_CURRENT"

# Sauvegarde /etc/hosts
cp /etc/hosts /etc/hosts.bak
echo "  Sauvegarde /etc/hosts -> /etc/hosts.bak"

# Supprime toutes les lignes existantes pour ce hostname (127.0.1.1 ou autre IP)
sed -i "/[[:space:]]${HOSTNAME_CURRENT}\(\.\| \|$\)/d" /etc/hosts

# Ajoute la bonne entrée hostname + FQDN
echo "${IP_ADDR} ${HOSTNAME_CURRENT}.local ${HOSTNAME_CURRENT}" >> /etc/hosts

echo "  /etc/hosts mis à jour : ${IP_ADDR} ${HOSTNAME_CURRENT}.local ${HOSTNAME_CURRENT}"

# Vérifie que le hostname se résout bien (requis par pve-cluster)
if ! getent hosts "$HOSTNAME_CURRENT" | grep -q "$IP_ADDR"; then
    echo "[WARNING] Le hostname '$HOSTNAME_CURRENT' ne résout pas vers $IP_ADDR."
    echo "          Vérifiez /etc/hosts manuellement si l'installation échoue."
fi

# =============================================================================
# 2. DÉPÔT PXVIRT
# =============================================================================
echo ""
echo "[2/6] Ajout du dépôt PXVIRT..."

# On force bookworm : c'est la seule version supportée par PXVIRT 8
# même si l'OS est Trixie ou une autre base Debian Bookworm
PXVIRT_SUITE="bookworm"

# Clé GPG
curl -fsSL https://mirrors.lierfang.com/pxcloud/lierfang.gpg \
    -o /etc/apt/trusted.gpg.d/lierfang.gpg
echo "  Clé GPG installée."

# Source list
echo "deb https://mirrors.lierfang.com/pxcloud/pxvirt ${PXVIRT_SUITE} main" \
    > /etc/apt/sources.list.d/pxvirt-sources.list
echo "  Dépôt ajouté : pxvirt ${PXVIRT_SUITE} main"

# =============================================================================
# 3. RÉSEAU — ifupdown2
# =============================================================================
echo ""
echo "[3/6] Configuration réseau (ifupdown2)..."

# Désactive NetworkManager s'il est présent
if systemctl list-unit-files NetworkManager.service &>/dev/null; then
    systemctl disable NetworkManager 2>/dev/null || true
    systemctl stop NetworkManager 2>/dev/null || true
    echo "  NetworkManager désactivé."
else
    echo "  NetworkManager non trouvé, rien à faire."
fi

apt-get update -qq
apt-get install -y ifupdown2

# Supprime le fichier temporaire s'il existe
[[ -f /etc/network/interfaces.new ]] && rm /etc/network/interfaces.new

# ── Détection interface et réseau ────────────────────────────────────────────
# Interface principale UP (hors loopback), préfère eth0/end0 (filaire)
INTERFACE=$(ip -o link show up \
    | awk -F': ' '{print $2}' \
    | grep -v lo \
    | grep -E '^(eth|end|enp|ens|eno)' \
    | head -n1)

# Fallback : toute interface UP hors loopback
if [[ -z "$INTERFACE" ]]; then
    INTERFACE=$(ip -o link show up | awk -F': ' '{print $2}' | grep -v lo | head -n1)
fi

if [[ -z "$INTERFACE" ]]; then
    echo "[ERROR] Aucune interface réseau active trouvée."
    exit 1
fi

echo "  Interface détectée : $INTERFACE"

# IP avec masque CIDR
IP_CIDR=$(ip -o -f inet addr show "$INTERFACE" | awk '{print $4}' | head -n1)
if [[ -z "$IP_CIDR" ]]; then
    echo "[ERROR] Impossible de récupérer l'IP de $INTERFACE."
    exit 1
fi

# Passerelle par défaut
GATEWAY=$(ip route | awk '/^default/{print $3}' | head -n1)
if [[ -z "$GATEWAY" ]]; then
    echo "[ERROR] Aucune passerelle par défaut trouvée."
    exit 1
fi

echo "  IP/Masque  : $IP_CIDR"
echo "  Passerelle : $GATEWAY"

# ── Écriture de /etc/network/interfaces ──────────────────────────────────────
INTERFACES_FILE="/etc/network/interfaces"
cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%F-%T)"
echo "  Sauvegarde $INTERFACES_FILE -> ${INTERFACES_FILE}.bak.*"

# Supprime toute config existante pour l'interface détectée et vmbr0
sed -i "/auto ${INTERFACE}/,/^\s*$/d" "$INTERFACES_FILE"
sed -i "/iface ${INTERFACE}/,/^\s*$/d" "$INTERFACES_FILE"
sed -i "/auto vmbr0/,/^\s*$/d" "$INTERFACES_FILE"
sed -i "/iface vmbr0/,/^\s*$/d" "$INTERFACES_FILE"

# S'assure que la base loopback est présente
if ! grep -q "iface lo" "$INTERFACES_FILE"; then
    cat >> "$INTERFACES_FILE" <<'LOEOF'

auto lo
iface lo inet loopback
LOEOF
fi

# Ajoute la config statique + bridge vmbr0
cat >> "$INTERFACES_FILE" <<EOF

# Interface physique (pont, pas d'IP directe)
auto ${INTERFACE}
iface ${INTERFACE} inet manual

# Bridge Proxmox/PXVIRT
auto vmbr0
iface vmbr0 inet static
    address ${IP_CIDR}
    gateway ${GATEWAY}
    bridge-ports ${INTERFACE}
    bridge-stp off
    bridge-fd 0
EOF

echo "  Configuration réseau écrite dans $INTERFACES_FILE"

# =============================================================================
# 4. INSTALLATION PXVIRT
# =============================================================================
echo ""
echo "[4/6] Installation de PXVIRT..."

# Pré-configure postfix en mode "local only" pour éviter le prompt interactif
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname -f)" | debconf-set-selections

apt-get update -qq

# Installation des paquets PXVIRT
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    proxmox-ve \
    pve-manager \
    qemu-server \
    pve-cluster \
    postfix \
    open-iscsi \
    chrony

echo ""
echo "  PXVIRT installé avec succès."

# =============================================================================
# 5. NETTOYAGE — Suppression de l'abonnement enterprise PVE (si présent)
# =============================================================================
echo ""
echo "[5/6] Nettoyage des sources enterprise Proxmox (si présentes)..."

for f in /etc/apt/sources.list.d/pve-enterprise.list \
          /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "$f" ]]; then
        sed -i 's/^deb/#deb/' "$f"
        echo "  Commenté : $f"
    fi
done

apt-get update -qq

# =============================================================================
# 6. RÉSUMÉ
# =============================================================================
echo ""
echo "============================================="
echo " Installation terminée !"
echo "============================================="
echo ""
echo "  Interface réseau : $INTERFACE"
echo "  Bridge vmbr0     : $IP_CIDR  (gw: $GATEWAY)"
echo "  Hostname         : $HOSTNAME_CURRENT ($IP_ADDR)"
echo ""
echo "  >> Redémarre le Pi avec : sudo reboot"
echo ""
echo "  Après le redémarrage, accède à l'interface web :"
echo "  https://${IP_ADDR}:8006"
echo "  Utilisateur : root"
echo "  Realm       : Linux PAM Standard Authentication"
echo ""
echo "  NOTE : Dans l'interface web, supprime l'IP de l'interface"
echo "         physique et crée un Linux Bridge (vmbr0) si ce n'est"
echo "         pas déjà fait automatiquement."
echo "============================================="
