#!/bin/bash

# Script per creare 5 board tramite Crossplane e configurarle automaticamente

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

BOARD_COUNT=${1:-5}

echo ""
echo "=========================================="
echo "  CREAZIONE $BOARD_COUNT BOARD"
echo "=========================================="
echo ""

# Verifica che il provider config esista
if ! kubectl get providerconfig s4t-provider-domain -n default >/dev/null 2>&1; then
    echo -e "${RED}ERROR: ProviderConfig 's4t-provider-domain' not found${NC}"
    echo "Esegui prima: cd stack4things-improved && ./deploy-complete-improved.sh"
    exit 1
fi

# Crea le board
echo "📦 Creazione $BOARD_COUNT board tramite Crossplane..."
for i in $(seq 1 $BOARD_COUNT); do
    TIMESTAMP=$(date +%s)
    cat <<EOF | kubectl apply -f -
apiVersion: iot.s4t.crossplane.io/v1alpha1
kind: Device
metadata:
  name: test-board-$i
  namespace: default
spec:
  forProvider:
    code: "TEST-BOARD-${TIMESTAMP}-$i"
    name: "Test Board $i"
    type: "virtual"
    location:
    - latitude: "38.1157"
      longitude: "13.3613"
      altitude: "0"
  providerConfigRef:
    name: s4t-provider-domain
EOF
    sleep 2
done

echo ""
echo "⏳ Attesa creazione board (15 secondi)..."
sleep 15

# Verifica board create
echo ""
echo "📊 Verifica board create:"
kubectl get device -n default

# Recupera board codes
echo ""
echo "📋 Board codes:"
BOARD_CODES=()
for device in $(kubectl get device -n default -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    BOARD_CODE=$(kubectl get device -n default "$device" -o jsonpath='{.spec.forProvider.code}')
    if [ -n "$BOARD_CODE" ] && [ "$BOARD_CODE" != "null" ]; then
        BOARD_CODES+=("$BOARD_CODE")
        echo "  - $BOARD_CODE"
    fi
done

if [ ${#BOARD_CODES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: Nessuna board trovata${NC}"
    exit 1
fi

# Crea Lightning Rod per ogni board
echo ""
echo "⚡ Creazione Lightning Rod per ogni board..."
cd "$(dirname "$0")/.." || exit 1

for board_code in "${BOARD_CODES[@]}"; do
    echo ""
    echo "  Creazione Lightning Rod per: $board_code"
    ./scripts/create-lightning-rod-for-board.sh "$board_code" 2>&1 | tail -5
    sleep 3
done

# Attesa pod ready
echo ""
echo "⏳ Attesa pod Lightning Rod ready..."
kubectl wait --for=condition=ready pod -n default -l app=lightning-rod --timeout=120s 2>&1 || echo "Alcuni pod potrebbero non essere ancora ready"

# Verifica e correggi wampagent
echo ""
echo "🔧 Verifica wampagent attivo..."
DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$DB_POD" ]; then
    # Assicura che solo un wagent sia ragent=1
    echo "  Correzione wagents duplicati..."
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "
        UPDATE wampagents SET ragent=0 WHERE ragent=1;
        UPDATE wampagents SET ragent=1, online=1 WHERE hostname=(SELECT hostname FROM (SELECT hostname FROM wampagents ORDER BY created_at DESC LIMIT 1) AS t);
    " 2>&1 || true
    
    ACTIVE_WAGENT=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT hostname FROM wampagents WHERE ragent=1 AND online=1 ORDER BY created_at DESC LIMIT 1;" 2>&1)
    if [ -z "$ACTIVE_WAGENT" ]; then
        echo -e "${YELLOW}  ⚠️  Nessun wagent attivo trovato, attesa creazione...${NC}"
        sleep 10
        ACTIVE_WAGENT=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT hostname FROM wampagents WHERE ragent=1 AND online=1 ORDER BY created_at DESC LIMIT 1;" 2>&1)
    fi
    
    if [ -n "$ACTIVE_WAGENT" ]; then
        echo "  Wagent attivo: $ACTIVE_WAGENT"
        
        # Aggiorna tutte le board con il wagent attivo
        echo "  Aggiornamento board con wagent attivo..."
        for board_code in "${BOARD_CODES[@]}"; do
            kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "UPDATE boards SET agent='$ACTIVE_WAGENT', status='registered' WHERE code='$board_code';" 2>&1 || true
        done
        echo -e "${GREEN}  ✅ Board configurate con wagent attivo${NC}"
    else
        echo -e "${YELLOW}  ⚠️  Nessun wagent attivo trovato, le board verranno configurate automaticamente${NC}"
    fi
    
    # Riavvia conductor per applicare le modifiche
    echo "  Riavvio conductor..."
    kubectl delete pod -n default -l io.kompose.service=iotronic-conductor 2>&1 | grep -v "Warning" || true
    sleep 10
fi

# Attesa connessione
echo ""
echo "⏳ Attesa connessione board (60 secondi)..."
sleep 60

# Verifica stato finale
echo ""
echo "=========================================="
echo "  STATO FINALE"
echo "=========================================="
echo ""

if [ -n "$DB_POD" ]; then
    echo "📊 Board e stato:"
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "SELECT code, status, agent FROM boards WHERE code LIKE 'TEST-BOARD%' ORDER BY code;" 2>&1
    
    echo ""
    ONLINE_COUNT=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT COUNT(*) FROM boards WHERE code LIKE 'TEST-BOARD%' AND status='online';" 2>&1 || echo "0")
    TOTAL_COUNT=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT COUNT(*) FROM boards WHERE code LIKE 'TEST-BOARD%';" 2>&1 || echo "0")
    echo "📈 Statistiche:"
    echo "  Board totali: $TOTAL_COUNT"
    echo "  Board online: $ONLINE_COUNT"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}✅ COMPLETATO${NC}"
echo "=========================================="
echo ""
echo "Le board dovrebbero connettersi e diventare online entro pochi minuti."
echo "Verifica lo stato dalla dashboard o con:"
echo "  kubectl exec -n default <db-pod> -- mysql -uroot -ps4t iotronic -e \"SELECT code, status FROM boards;\""
echo ""
