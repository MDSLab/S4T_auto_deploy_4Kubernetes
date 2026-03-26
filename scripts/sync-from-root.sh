#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[INFO] Root: ${ROOT_DIR}"
echo "[INFO] Dest: ${DEST_DIR}"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "${src}" ]]; then
    mkdir -p "$(dirname "${dst}")"
    rsync -a "${src}" "${dst}"
    echo "[OK] Copied ${src} -> ${dst}"
  else
    echo "[SKIP] Missing ${src}"
  fi
}

# Crossplane
copy_if_exists "${ROOT_DIR}/crossplane-provider/" "${DEST_DIR}/crossplane-provider/"

# Stack4Things (active deploy only)
copy_if_exists "${ROOT_DIR}/stack4things-improved/" "${DEST_DIR}/stack4things-improved/"

# Ops scripts
copy_if_exists "${ROOT_DIR}/setup-all.sh" "${DEST_DIR}/ops/"
copy_if_exists "${ROOT_DIR}/verify-deployment.sh" "${DEST_DIR}/ops/"
copy_if_exists "${ROOT_DIR}/get_helm.sh" "${DEST_DIR}/ops/"
copy_if_exists "${ROOT_DIR}/Makefile" "${DEST_DIR}/ops/"

# Docs
copy_if_exists "${ROOT_DIR}/README.md" "${DEST_DIR}/docs/"
copy_if_exists "${ROOT_DIR}/START_HERE.md" "${DEST_DIR}/docs/"
copy_if_exists "${ROOT_DIR}/QUICKSTART.md" "${DEST_DIR}/docs/"
copy_if_exists "${ROOT_DIR}/DEPLOYMENT_SETUP.md" "${DEST_DIR}/docs/"
copy_if_exists "${ROOT_DIR}/HOW_TO_USE.txt" "${DEST_DIR}/docs/"
copy_if_exists "${ROOT_DIR}/XRD_VERIFICATION_REPORT.md" "${DEST_DIR}/docs/"

echo "[DONE] Sync completed."
