#!/bin/bash

# Script per compilare settings.json per tutte le board esistenti
# Aggiorna settings.json con board_code e URL WSS di Crossbar

set -euo pipefail

# Colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configurazione kubeconfig
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
elif [ -f /etc/rancher/k3s/k3s.yaml_backup ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml_backup
else
    echo -e "${RED}ERROR: kubeconfig not found${NC}"
    exit 1
fi

# Configurazione servizi
CROSSBAR_SERVICE="crossbar.default.svc.cluster.local"
CROSSBAR_PORT="8181"
WSS_URL="wss://${CROSSBAR_SERVICE}:${CROSSBAR_PORT}/"
WAMP_REALM="s4t"

echo ""
echo "=========================================="
echo "  COMPILAZIONE SETTINGS.JSON PER TUTTE LE BOARD"
echo "=========================================="
echo ""
echo "WSS URL: $WSS_URL"
echo "WAMP Realm: $WAMP_REALM"
echo ""

# Ottieni token Keystone (se necessario, per fallback UUID)
KEYSTONE_SERVICE="keystone.default.svc.cluster.local"
KEYSTONE_PORT=$(kubectl get svc keystone -n default -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "5000")
TOKEN_RESPONSE=$(curl -s -i -X POST "http://${KEYSTONE_SERVICE}:${KEYSTONE_PORT}/v3/auth/tokens" \
    -H "Content-Type: application/json" \
    -d '{"auth":{"identity":{"methods":["password"],"password":{"user":{"name":"admin","domain":{"id":"default"},"password":"s4t"}}},"scope":{"project":{"name":"admin","domain":{"id":"default"}}}}}' 2>/dev/null || echo "")
TOKEN=$(echo "$TOKEN_RESPONSE" | grep -i "X-Subject-Token" | cut -d' ' -f2 | tr -d '\r\n' || echo "")

IOTRONIC_SERVICE="iotronic-conductor.default.svc.cluster.local"
IOTRONIC_PORT=$(kubectl get svc iotronic-conductor -n default -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8812")

# Per ogni Device Crossplane, compila settings.json nel pod corrispondente
BOARD_COUNT=0
SUCCESS_COUNT=0

for device in $(kubectl get device -n default -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    DEVICE_JSON=$(kubectl get device -n default "$device" -o json 2>/dev/null)
    BOARD_CODE=$(echo "$DEVICE_JSON" | jq -r '.spec.forProvider.code // empty')
    
    if [ -z "$BOARD_CODE" ] || [ "$BOARD_CODE" == "null" ]; then
        echo -e "${YELLOW}⚠️  Device $device: code mancante, salto...${NC}"
        continue
    fi
    
    BOARD_COUNT=$((BOARD_COUNT + 1))
    echo ""
    echo "Board: $BOARD_CODE"
    echo "  Nota: UUID verrà aggiunto dal cloud alla prima connessione"
    
    # Trova il pod Lightning Rod
    POD_NAME=$(kubectl get pod -n default -l board-code="${BOARD_CODE}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$POD_NAME" ]; then
        echo -e "${YELLOW}  ⚠️  Pod Lightning Rod non trovato o non in Running${NC}"
        echo "  Crea il pod con: ./scripts/create-lightning-rod-for-board.sh $BOARD_CODE"
        continue
    fi
    
    echo "  Pod: $POD_NAME"
    
    # Genera il JSON per settings.json
    # NOTA: UUID non viene incluso - verrà aggiunto dal cloud alla prima connessione
    SETTINGS_JSON=$(jq -n \
        --arg code "$BOARD_CODE" \
        --arg url "$WSS_URL" \
        --arg realm "$WAMP_REALM" \
        '{
            "iotronic": {
                "board": {
                    "code": $code
                },
                "wamp": {
                    "registration-agent": {
                        "url": $url,
                        "realm": $realm
                    }
                }
            }
        }')
    
    # Compila settings.json nel container
    echo "$SETTINGS_JSON" | kubectl exec -i -n default "$POD_NAME" -- /bin/bash -c "
        cat > /etc/iotronic/settings.json
        chmod 644 /etc/iotronic/settings.json
        cp /etc/iotronic/settings.json /var/lib/iotronic/settings.json
        chmod 644 /var/lib/iotronic/settings.json
        echo '[INFO] settings.json compilato per board: $BOARD_CODE'
    " 2>&1 | grep -v "^$" || true
    
    echo -e "${GREEN}  ✅ settings.json compilato${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done

echo ""
echo "=========================================="
echo -e "${GREEN}✅ COMPLETATO${NC}"
echo "=========================================="
echo ""
echo "Board processate: $BOARD_COUNT"
echo "Settings.json compilati: $SUCCESS_COUNT"
echo ""
