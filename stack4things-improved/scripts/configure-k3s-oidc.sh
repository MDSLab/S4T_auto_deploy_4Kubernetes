#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo "=========================================="
echo "  CONFIGURAZIONE K3S PER OIDC"
echo "=========================================="
echo ""

# Verificare se siamo root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: Questo script deve essere eseguito come root (sudo)${NC}"
    exit 1
fi

# Configurazione OIDC
KEYCLOAK_ISSUER_URL="https://keycloak.keycloak.svc.cluster.local:8443/realms/stack4things"
OIDC_CLIENT_ID="kubernetes"
OIDC_USERNAME_CLAIM="preferred_username"
OIDC_GROUPS_CLAIM="groups"

# File di configurazione k3s
K3S_CONFIG_FILE="/etc/rancher/k3s/config.yaml"
K3S_SERVICE_FILE="/etc/systemd/system/k3s.service"

echo "1. Creazione configurazione k3s per OIDC..."

# Creare directory se non esiste
mkdir -p /etc/rancher/k3s

# Creare o aggiornare config.yaml
if [ ! -f "$K3S_CONFIG_FILE" ]; then
    cat > "$K3S_CONFIG_FILE" << EOF
kube-apiserver-arg:
  - "oidc-issuer-url=$KEYCLOAK_ISSUER_URL"
  - "oidc-client-id=$OIDC_CLIENT_ID"
  - "oidc-username-claim=$OIDC_USERNAME_CLAIM"
  - "oidc-groups-claim=$OIDC_GROUPS_CLAIM"
EOF
    echo -e "${GREEN}✔ File $K3S_CONFIG_FILE creato${NC}"
else
    # Verificare se OIDC è già configurato
    if grep -q "oidc-issuer-url" "$K3S_CONFIG_FILE"; then
        echo -e "${YELLOW}⚠️  OIDC già configurato in $K3S_CONFIG_FILE${NC}"
    else
        # Aggiungere configurazione OIDC
        cat >> "$K3S_CONFIG_FILE" << EOF

kube-apiserver-arg:
  - "oidc-issuer-url=$KEYCLOAK_ISSUER_URL"
  - "oidc-client-id=$OIDC_CLIENT_ID"
  - "oidc-username-claim=$OIDC_USERNAME_CLAIM"
  - "oidc-groups-claim=$OIDC_GROUPS_CLAIM"
EOF
        echo -e "${GREEN}✔ Configurazione OIDC aggiunta a $K3S_CONFIG_FILE${NC}"
    fi
fi

echo "2. Riavviare k3s per applicare le modifiche..."
systemctl daemon-reload
systemctl restart k3s

echo "3. Attesa k3s ready..."
sleep 10
kubectl get nodes || {
    echo -e "${RED}ERROR: k3s non risponde dopo il riavvio${NC}"
    exit 1
}

echo ""
echo "=========================================="
echo -e "${GREEN}✅ K3S CONFIGURATO PER OIDC!${NC}"
echo "=========================================="
echo ""
echo "Nota: Per utilizzare l'autenticazione OIDC:"
echo "  1. Ottenere un token JWT da Keycloak"
echo "  2. Configurare kubectl con il token:"
echo "     kubectl config set-credentials oidc-user \\"
echo "       --token=<JWT_TOKEN>"
echo "  3. Configurare il contesto:"
echo "     kubectl config set-context oidc-context \\"
echo "       --cluster=default \\"
echo "       --user=oidc-user"
echo ""
