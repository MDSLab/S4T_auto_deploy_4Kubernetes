#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="default"
BOARD_FILTER="TEST-BOARD%"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[ERR] kubectl non trovato"
  exit 1
fi

DB_POD=$(kubectl get pods -n "$NAMESPACE" -o name \
  | grep -E 'iotronic-db|mariadb|mysql|db' \
  | head -1 \
  | sed 's#pod/##' || true)

if [[ -z "${DB_POD}" ]]; then
  echo "[ERR] DB pod non trovato nel namespace ${NAMESPACE}"
  exit 1
fi

ACTIVE_WAGENT=$(kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  mysql -uroot -ps4t iotronic -Nse "SELECT hostname FROM wampagents WHERE ragent=1 AND online=1 ORDER BY created_at DESC LIMIT 1;" \
  2>/dev/null || true)

if [[ -n "${ACTIVE_WAGENT}" ]]; then
  kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
    mysql -uroot -ps4t iotronic -e "UPDATE boards SET agent='${ACTIVE_WAGENT}' WHERE code LIKE '${BOARD_FILTER}' AND (agent IS NULL OR agent='');" >/dev/null
fi

kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  mysql -uroot -ps4t iotronic -e "
    UPDATE boards b
    INNER JOIN (
      SELECT DISTINCT board_uuid
      FROM sessions
      WHERE valid=1
    ) s ON s.board_uuid = b.uuid
    SET b.status='online'
    WHERE b.code LIKE '${BOARD_FILTER}';
  " >/dev/null

echo "[INFO] Stato board aggiornato da sessioni valide"
kubectl exec -n "$NAMESPACE" "$DB_POD" -- \
  mysql -uroot -ps4t iotronic -e "SELECT code,status,agent FROM boards WHERE code LIKE '${BOARD_FILTER}' ORDER BY code;"
