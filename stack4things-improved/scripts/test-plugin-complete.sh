#!/bin/bash

set -euo pipefail

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="simple-logger"
BOARD_CODE="${1:-}"

if [ -z "$BOARD_CODE" ]; then
    echo -e "${RED}Usage: $0 <BOARD_CODE>${NC}"
    echo ""
    echo "Example:"
    echo "  $0 TEST-BOARD-1234567890-1"
    exit 1
fi

echo ""
echo "=========================================="
echo "  TEST COMPLETO PLUGIN CON CROSSPLANE"
echo "=========================================="
echo ""
echo "Plugin: $PLUGIN_NAME"
echo "Board: $BOARD_CODE"
echo ""

# Step 1: Crea plugin
echo "STEP 1: Creazione plugin..."
kubectl apply -f "$SCRIPT_DIR/../examples/plugin-simple-logger.yaml" 2>&1 | grep -v "Warning" || true

echo "Attesa creazione plugin (60 secondi)..."
for i in {1..12}; do
    sleep 5
    READY=$(kubectl get plugin "$PLUGIN_NAME" -n default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    SYNCED=$(kubectl get plugin "$PLUGIN_NAME" -n default -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "Unknown")
    echo "  [$i/12] Ready: $READY, Synced: $SYNCED"
    if [ "$READY" == "True" ] && [ "$SYNCED" == "True" ]; then
        echo -e "${GREEN}Plugin creato con successo!${NC}"
        break
    fi
done

echo ""
echo "Stato plugin:"
kubectl get plugin "$PLUGIN_NAME" -n default 2>&1 || true

# Verifica nel database
echo ""
echo "Verifica nel database:"
DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$DB_POD" ]; then
    PLUGIN_UUID=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT uuid FROM plugins WHERE name='Simple Logger' LIMIT 1;" 2>/dev/null || echo "")
    if [ -n "$PLUGIN_UUID" ]; then
        echo -e "${GREEN}Plugin trovato nel database: $PLUGIN_UUID${NC}"
    else
        echo -e "${YELLOW}Plugin non trovato nel database${NC}"
        echo "Controlla i log del provider:"
        echo "  kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-s4t --tail=50 | grep -i plugin"
        exit 1
    fi
else
    echo -e "${RED}Database pod non trovato${NC}"
    exit 1
fi

# Step 2: Inietta plugin
echo ""
echo "STEP 2: Iniezione plugin nella board..."
"$SCRIPT_DIR/inject-plugin-using-crd.sh" "$BOARD_CODE" "$PLUGIN_NAME"

echo ""
echo "Attesa iniezione (10 secondi)..."
sleep 10

# Verifica iniezione
echo ""
echo "Verifica iniezione nel database:"
if [ -n "$DB_POD" ] && [ -n "$PLUGIN_UUID" ]; then
    BOARD_UUID=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT uuid FROM boards WHERE code='$BOARD_CODE' LIMIT 1;" 2>/dev/null || echo "")
    if [ -n "$BOARD_UUID" ]; then
        INJECTED=$(kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -Nse "SELECT COUNT(*) FROM injected_plugins WHERE board='$BOARD_UUID' AND plugin='$PLUGIN_UUID';" 2>/dev/null || echo "0")
        if [ "$INJECTED" == "1" ]; then
            echo -e "${GREEN}Plugin iniettato con successo!${NC}"
        else
            echo -e "${YELLOW}Plugin non ancora iniettato (count: $INJECTED)${NC}"
        fi
    fi
fi

echo ""
echo "=========================================="
echo -e "${GREEN}TEST COMPLETATO!${NC}"
echo "=========================================="
echo ""
echo "Per verificare nella dashboard:"
echo "  1. Accedi alla dashboard"
echo "  2. Vai alla sezione Plugins - dovresti vedere 'Simple Logger'"
echo "  3. Vai alla board $BOARD_CODE - dovresti vedere il plugin iniettato"
echo ""
echo "Per vedere i log del plugin (quando avviato):"
echo "  kubectl logs -n default -l app=lightning-rod | grep -i 'simple logger\|Value:'"
