#!/usr/bin/env bash
set -euo pipefail

# Mirror container images to a Docker Hub namespace without rebuilding.
# Supports inventory from repository manifests and/or an explicit images list.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEST_NAMESPACE=""
LOGIN_USER=""
DEST_CREDS=""
SRC_CREDS=""
IMAGES_FILE=""
OUTPUT_FILE=""
FROM_REPO=false
DRY_RUN=false
ONLY_USERS=""
SEEN_DESTS_FILE=""

usage() {
  cat <<'EOF'
Uso:
  mirror-images-dockerhub.sh --namespace <dockerhub_namespace> [opzioni]

Opzioni:
  --namespace <name>       Namespace Docker Hub di destinazione (utente o organization, obbligatorio)
  --user <name>            Alias retrocompatibile di --namespace
  --login-user <name>      Account personale usato per login Docker Hub (opzionale)
  --dest-creds <u:p|u:t>   Credenziali destinazione per skopeo (user:password o user:token)
  --src-creds <u:p|u:t>    Credenziali sorgente per pull con skopeo (evita rate limit)
  --images-file <path>     File con elenco immagini (una per riga)
  --from-repo              Estrae immagini da manifest/Dockerfile/compose del repository
  --output-file <path>     Dove salvare l'inventory (default: ./images.txt)
  --only-users <u1,u2>     Filtra immagini sorgente per namespace utente (CSV)
  --dry-run                Stampa le azioni senza copiare/pushare
  -h, --help               Mostra questo aiuto

Esempi:
  ./scripts/mirror-images-dockerhub.sh --namespace mioaccount --from-repo
  ./scripts/mirror-images-dockerhub.sh --namespace mia-org --login-user mioaccount --images-file ./images.txt
  ./scripts/mirror-images-dockerhub.sh --namespace mia-org --dest-creds mioaccount:token_rw --images-file ./images.txt
  ./scripts/mirror-images-dockerhub.sh --namespace mia-org --src-creds mioaccount:token_rw --dest-creds mioaccount:token_rw --images-file ./images.txt
  ./scripts/mirror-images-dockerhub.sh --namespace mia-org --from-repo --only-users lucadagati,mariorossi851234
  ./scripts/mirror-images-dockerhub.sh --namespace mia-org --from-repo --dry-run

Prerequisiti:
  - docker login -u <account_personale>
  - skopeo installato
EOF
}

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

err() {
  echo "[ERROR] $*" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "Comando mancante: ${cmd}"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)
        DEST_NAMESPACE="${2:-}"
        shift 2
        ;;
      --user)
        DEST_NAMESPACE="${2:-}"
        shift 2
        ;;
      --login-user)
        LOGIN_USER="${2:-}"
        shift 2
        ;;
      --dest-creds)
        DEST_CREDS="${2:-}"
        shift 2
        ;;
      --src-creds)
        SRC_CREDS="${2:-}"
        shift 2
        ;;
      --images-file)
        IMAGES_FILE="${2:-}"
        shift 2
        ;;
      --output-file)
        OUTPUT_FILE="${2:-}"
        shift 2
        ;;
      --only-users)
        ONLY_USERS="${2:-}"
        shift 2
        ;;
      --from-repo)
        FROM_REPO=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Opzione non riconosciuta: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "${DEST_NAMESPACE}" ]]; then
    err "Specifica --namespace <dockerhub_namespace>"
    usage
    exit 1
  fi

  if [[ "${FROM_REPO}" == false && -z "${IMAGES_FILE}" ]]; then
    err "Devi usare almeno una sorgente: --from-repo o --images-file"
    usage
    exit 1
  fi

  if [[ -z "${OUTPUT_FILE}" ]]; then
    OUTPUT_FILE="${ROOT_DIR}/images.txt"
  fi
}

collect_from_repo() {
  local out_file="$1"

  log "Raccolta immagini dal repository in corso..."

  local tmp_file
  tmp_file="$(mktemp)"

  (
    cd "${ROOT_DIR}"

    grep -RhoE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv --exclude-dir=logs 'image:[[:space:]]*[^[:space:]]+' . \
      | sed -E 's/image:[[:space:]]*//' || true

    grep -RhoE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv --exclude-dir=logs '^FROM[[:space:]]+[^[:space:]]+' . \
      | sed -E 's/^FROM[[:space:]]+//' \
      | sed -E 's/[[:space:]]+AS[[:space:]]+.*$//' || true
  ) > "${tmp_file}"

  sed -E "s/[\"',]$//" "${tmp_file}" \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | grep -E '.' \
    | sort -u > "${out_file}"

  rm -f "${tmp_file}"

  log "Inventory repository salvato in: ${out_file}"
}

normalize_target_repo() {
  local image_no_registry="$1"
  echo "${image_no_registry}" \
    | tr '/:@' '---' \
    | tr -cd 'A-Za-z0-9._-'
}

strip_source_namespace() {
  local image_no_registry="$1"

  # Remove first path segment (typically source user/org) from destination naming.
  if [[ "${image_no_registry}" == */* ]]; then
    echo "${image_no_registry#*/}"
  else
    echo "${image_no_registry}"
  fi
}

image_allowed_by_user_filter() {
  local image="$1"

  if [[ -z "${ONLY_USERS}" ]]; then
    return 0
  fi

  local users_csv="${ONLY_USERS// /}"
  local IFS=','
  local users
  read -r -a users <<< "${users_csv}"

  local user
  for user in "${users[@]}"; do
    [[ -z "${user}" ]] && continue
    if [[ "${image}" == "${user}/"* || "${image}" == "docker.io/${user}/"* || "${image}" == "index.docker.io/${user}/"* ]]; then
      return 0
    fi
  done

  return 1
}

collect_user_images_from_repo() {
  local out_file="$1"

  if [[ -z "${ONLY_USERS}" ]]; then
    : > "${out_file}"
    return 0
  fi

  local users_csv="${ONLY_USERS// /}"
  local user_regex
  user_regex="$(echo "${users_csv}" | tr ',' '|' | sed -E 's/[^A-Za-z0-9._|-]//g')"

  if [[ -z "${user_regex}" ]]; then
    : > "${out_file}"
    return 0
  fi

  (
    cd "${ROOT_DIR}"
    find . -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' -o -name '*.md' -o -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.txt' -o -name '*.mk' -o -name 'Makefile' \) -print0 \
      | xargs -0 grep -hEo "(docker\\.io/|index\\.docker\\.io/)?(${user_regex})/[A-Za-z0-9._/-]+([:@][A-Za-z0-9._-]+)?" || true
  ) \
    | grep -Ev '\.git$' \
    | sort -u > "${out_file}"
}

is_registry_prefix() {
  local first_part="$1"
  if [[ "${first_part}" == *.* || "${first_part}" == *:* || "${first_part}" == "localhost" ]]; then
    return 0
  fi
  return 1
}

mirror_image() {
  local src="$1"

  local base
  local tag
  local ref

  if [[ "${src}" == *@sha256:* ]]; then
    base="${src%@sha256:*}"
    tag="sha-$(echo "${src}" | sed -E 's#.*@sha256:([a-f0-9]+).*#\1#' | cut -c1-12)"
    ref="${src}"
  else
    if [[ "${src}" == *:* ]]; then
      base="${src%:*}"
      tag="${src##*:}"
    else
      base="${src}"
      tag="latest"
    fi
    # skopeo docker-daemon requires an explicit tag or digest.
    ref="${base}:${tag}"
  fi

  local base_no_registry="${base}"
  if [[ "${base}" == */* ]]; then
    local first="${base%%/*}"
    local rest="${base#*/}"
    if is_registry_prefix "${first}"; then
      base_no_registry="${rest}"
    fi
  fi

  local repo
  local no_source_namespace
  no_source_namespace="$(strip_source_namespace "${base_no_registry}")"

  repo="$(normalize_target_repo "${no_source_namespace}")"
  local dst="docker.io/${DEST_NAMESPACE}/${repo}:${tag}"

  if grep -Fxq "${dst}" "${SEEN_DESTS_FILE}"; then
    log "Skip duplicato destinazione: ${dst}"
    return 0
  fi
  echo "${dst}" >> "${SEEN_DESTS_FILE}"

  local src_transport
  if docker image inspect "${ref}" >/dev/null 2>&1; then
    src_transport="docker-daemon:${ref}"
  else
    local ref_no_registry="${ref}"
    if [[ "${ref_no_registry}" == docker.io/* ]]; then
      ref_no_registry="${ref_no_registry#docker.io/}"
    elif [[ "${ref_no_registry}" == index.docker.io/* ]]; then
      ref_no_registry="${ref_no_registry#index.docker.io/}"
    fi

    if docker image inspect "${ref_no_registry}" >/dev/null 2>&1; then
      src_transport="docker-daemon:${ref_no_registry}"
    else
      src_transport="docker://${ref}"
    fi
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    echo "[DRY-RUN] ${src_transport} -> docker://${dst}"
    return 0
  fi

  if [[ -n "${SRC_CREDS}" && -n "${DEST_CREDS}" ]]; then
    skopeo copy --all --src-creds "${SRC_CREDS}" --dest-creds "${DEST_CREDS}" "${src_transport}" "docker://${dst}"
  elif [[ -n "${SRC_CREDS}" ]]; then
    skopeo copy --all --src-creds "${SRC_CREDS}" "${src_transport}" "docker://${dst}"
  elif [[ -n "${DEST_CREDS}" ]]; then
    skopeo copy --all --dest-creds "${DEST_CREDS}" "${src_transport}" "docker://${dst}"
  else
    skopeo copy --all "${src_transport}" "docker://${dst}"
  fi
  echo "[OK] ${ref} -> ${dst}"
}

prepare_inventory() {
  local merged_file
  merged_file="$(mktemp)"

  if [[ "${FROM_REPO}" == true ]]; then
    collect_from_repo "${OUTPUT_FILE}"
    cat "${OUTPUT_FILE}" >> "${merged_file}"
  fi

  if [[ -n "${IMAGES_FILE}" ]]; then
    if [[ ! -f "${IMAGES_FILE}" ]]; then
      err "File immagini non trovato: ${IMAGES_FILE}"
      rm -f "${merged_file}"
      exit 1
    fi
    cat "${IMAGES_FILE}" >> "${merged_file}"
  fi

  if [[ "${FROM_REPO}" == true && -n "${ONLY_USERS}" ]]; then
    local user_scan_file
    user_scan_file="$(mktemp)"
    collect_user_images_from_repo "${user_scan_file}"
    cat "${user_scan_file}" >> "${merged_file}"
    rm -f "${user_scan_file}"
  fi

  sed -E 's/#.*$//' "${merged_file}" \
    | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | grep -E '.' \
    | sort -u > "${OUTPUT_FILE}"

  if [[ -n "${ONLY_USERS}" ]]; then
    local before_count
    before_count="$(wc -l < "${OUTPUT_FILE}" | tr -d ' ')"

    local filtered_file
    filtered_file="$(mktemp)"

    while IFS= read -r image; do
      [[ -z "${image}" ]] && continue
      if image_allowed_by_user_filter "${image}"; then
        echo "${image}" >> "${filtered_file}"
      fi
    done < "${OUTPUT_FILE}"

    sort -u "${filtered_file}" > "${OUTPUT_FILE}"

    local after_count
    after_count="$(wc -l < "${OUTPUT_FILE}" | tr -d ' ')"
    log "Filtro namespace applicato (${ONLY_USERS}): ${before_count} -> ${after_count}"

    rm -f "${filtered_file}"
  fi

  rm -f "${merged_file}"
}

main() {
  parse_args "$@"
  require_cmd docker
  require_cmd grep
  require_cmd sed
  require_cmd sort

  if [[ "${DRY_RUN}" == false ]]; then
    require_cmd skopeo
  fi

  SEEN_DESTS_FILE="$(mktemp)"
  trap 'rm -f "${SEEN_DESTS_FILE}"' EXIT

  prepare_inventory

  local count
  count="$(wc -l < "${OUTPUT_FILE}" | tr -d ' ')"
  log "Immagini uniche da processare: ${count}"
  log "Inventory file: ${OUTPUT_FILE}"

  if [[ "${count}" == "0" ]]; then
    warn "Nessuna immagine trovata. Esco."
    exit 0
  fi

  if [[ "${DRY_RUN}" == false ]]; then
    if [[ -n "${LOGIN_USER}" ]]; then
      log "Assicurati di aver eseguito: docker login -u ${LOGIN_USER}"
    else
      log "Assicurati di aver eseguito: docker login -u <account_personale_con_permessi_su_${DEST_NAMESPACE}>"
    fi
  fi

  while IFS= read -r image; do
    [[ -z "${image}" ]] && continue
    mirror_image "${image}"
  done < "${OUTPUT_FILE}"

  log "Completato."
}

main "$@"
