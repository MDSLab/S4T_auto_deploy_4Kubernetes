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

echo ""
echo "=========================================="
echo "  VERIFICA PLUGIN E INIEZIONI"
echo "=========================================="
echo ""

echo "1. Plugin Crossplane:"
kubectl get plugin -n default 2>&1 || echo "  Nessun plugin trovato"
echo ""

echo "2. Plugin nel database:"
DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$DB_POD" ]; then
    kubectl exec -n default "$DB_POD" -- mysql -h127.0.0.1 -uiotronic -punime iotronic -e "SELECT uuid, name FROM plugins LIMIT 10;" 2>/dev/null || echo "  Errore accesso database"
else
    echo "  Database pod non trovato"
fi
echo ""

echo "3. Plugin iniettati nelle board:"
if [ -n "$DB_POD" ]; then
    kubectl exec -n default "$DB_POD" -- mysql -h127.0.0.1 -uiotronic -punime iotronic -e "
        SELECT 
            b.name as board_name,
            b.code as board_code,
            p.name as plugin_name,
            ip.plugin_uuid,
            ip.status,
            ip.onboot
        FROM injection_plugins ip
        JOIN boards b ON ip.board_uuid = b.uuid
        JOIN plugins p ON ip.plugin_uuid = p.uuid
        LIMIT 10;
    " 2>/dev/null || echo "  Nessun plugin iniettato o errore query"
else
    echo "  Database pod non trovato"
fi
echo ""

echo "4. BoardPluginInjection CRD:"
kubectl get boardplugininjection -n default 2>&1 || echo "  Nessuna injection trovata"
echo ""

echo "5. Stato Crossplane Provider:"
kubectl get provider -n crossplane-system 2>&1 | grep s4t || echo "  Provider non trovato"
echo ""
