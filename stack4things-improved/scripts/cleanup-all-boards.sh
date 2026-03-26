#!/bin/bash

# Script per pulire tutte le board dal database e cancellare i Lightning Rod pods

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

echo ""
echo "=========================================="
echo "  PULIZIA BOARD E LIGHTNING ROD"
echo "=========================================="
echo ""

# Conferma
read -p "Sei sicuro di voler cancellare tutte le board? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Operazione annullata."
    exit 0
fi

# Cancella tutti i Device Crossplane
echo "🗑️  Cancellazione Device Crossplane..."
kubectl delete device -n default --all 2>&1 | grep -v "Warning" || true
sleep 5

# Cancella tutti i Lightning Rod pods
echo "🗑️  Cancellazione Lightning Rod pods..."
kubectl delete pod -n default -l app=lightning-rod 2>&1 | grep -v "Warning" || true
sleep 5

# Cancella tutti i Lightning Rod deployments
echo "🗑️  Cancellazione Lightning Rod deployments..."
kubectl delete deployment -n default -l app=lightning-rod 2>&1 | grep -v "Warning" || true
sleep 5

# Pulisci il database
DB_POD=$(kubectl get pod -n default -l io.kompose.service=iotronic-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$DB_POD" ]; then
    echo "🗑️  Pulizia database..."
    
    # Cancella tutte le board
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "DELETE FROM boards;" 2>&1 || echo -e "${YELLOW}⚠️  Errore nella cancellazione board${NC}"
    
    # Cancella tutte le sessioni WAMP (se la tabella esiste)
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "DELETE FROM wamp_sessions;" 2>&1 || echo -e "${YELLOW}⚠️  Tabella wamp_sessions non trovata o già vuota${NC}"
    
    # Cancella plugin, servizi, ecc.
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "
        DELETE FROM plugins;
        DELETE FROM services;
        DELETE FROM webservices;
        DELETE FROM ports_on_boards;
        DELETE FROM injected_plugins;
        DELETE FROM injected_services;
    " 2>&1 || echo -e "${YELLOW}⚠️  Errore nella cancellazione di plugin/servizi${NC}"
    
    # Mantieni solo il wagent più recente come ragent=1
    # NON cancelliamo i wampagents, ma assicuriamoci che solo uno sia attivo
    echo "🔧 Correzione wampagents (solo uno attivo)..."
    kubectl exec -n default "$DB_POD" -- mysql -uroot -ps4t iotronic -e "
        UPDATE wampagents SET ragent=0 WHERE ragent=1;
        UPDATE wampagents SET ragent=1, online=1 WHERE hostname=(SELECT hostname FROM (SELECT hostname FROM wampagents ORDER BY created_at DESC LIMIT 1) AS t);
    " 2>&1 || echo -e "${YELLOW}⚠️  Errore nella correzione wampagents${NC}"
    
    echo -e "${GREEN}✔ Database pulito e wagents corretti${NC}"
else
    echo -e "${YELLOW}⚠️  Database pod not found, skipping database cleanup${NC}"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}✅ PULIZIA COMPLETATA${NC}"
echo "=========================================="
echo ""
