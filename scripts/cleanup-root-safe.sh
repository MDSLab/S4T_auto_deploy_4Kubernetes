#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNIFIED_DIR="${ROOT_DIR}/unified-deploy"
BACKUP_DIR="${ROOT_DIR}/_pre_cleanup_backup_$(date +%Y%m%d_%H%M%S)"

if [[ "${1:-}" != "--confirm" ]]; then
  echo "Uso: $0 --confirm"
  echo "Questo script sposta i contenuti root nel backup mantenendo solo unified-deploy e .git/.gitignore"
  exit 1
fi

mkdir -p "${BACKUP_DIR}"
echo "[INFO] Backup dir: ${BACKUP_DIR}"

shopt -s dotglob nullglob
for item in "${ROOT_DIR}"/*; do
  base="$(basename "${item}")"
  if [[ "${base}" == ".git" || "${base}" == ".gitignore" || "${base}" == "unified-deploy" ]]; then
    echo "[KEEP] ${base}"
    continue
  fi

  mv "${item}" "${BACKUP_DIR}/"
  echo "[MOVE] ${base} -> ${BACKUP_DIR}/"
done

cat <<EOF
[DONE] Pulizia completata.
Contenuti spostati in: ${BACKUP_DIR}
Cartella operativa unica: ${UNIFIED_DIR}
EOF
