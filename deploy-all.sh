#!/usr/bin/env bash
# Baut und pusht ausschliesslich die Images fuer:
#   - Kaspa Node (rusty-kaspa Node + kaspa-node UI/API)
#   - Kaspa Stratum Bridge (stratum-bridge + stratum-dashboard)
# Die Anmeldung wird einmalig via scripts/docker-login.ps1 bzw. docker-login.sh
# hinterlegt; deploy-all.sh pusht standardmaessig (PUSH_IMAGES=1).
# Mit PUSH_IMAGES=0 werden die Images nur lokal gebaut (kein Push).
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
KASPA_TAG="${KASPA_TAG:-}"
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64}"
BUILDX_BUILDER_NAME="${BUILDX_BUILDER_NAME:-kaspa-amd64}"
BUILDX_BUILDER_DRIVER="${BUILDX_BUILDER_DRIVER:-docker}"
# MODULES: Kommagetrennte Liste der zu bauenden Module (Standard: leer = alle).
# Beispiel: MODULES="kaspa-stratum-dashboard" ./deploy-all.sh
MODULES="${MODULES:-}"

require_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  local current_context
  current_context="$(docker context show 2>/dev/null || echo "unknown")"
  echo "Docker daemon is not reachable (context: ${current_context})." >&2
  echo "Start Docker Desktop/daemon first, then retry." >&2
  exit 1
}

require_buildx() {
  if docker buildx version >/dev/null 2>&1; then
    return 0
  fi

  echo "Docker buildx is required but not available." >&2
  exit 1
}

ensure_buildx_builder() {
  if [[ "$BUILDX_BUILDER_DRIVER" == "docker" ]]; then
    # Use the active docker context as the buildx builder name.
    BUILDX_BUILDER_NAME="$(docker context show)"
    docker buildx use "$BUILDX_BUILDER_NAME" >/dev/null 2>&1 || true
    docker buildx inspect "$BUILDX_BUILDER_NAME" >/dev/null
    return 0
  fi

  if ! docker buildx inspect "$BUILDX_BUILDER_NAME" >/dev/null 2>&1; then
    docker buildx create \
      --name "$BUILDX_BUILDER_NAME" \
      --driver "$BUILDX_BUILDER_DRIVER" \
      --use >/dev/null
  else
    docker buildx use "$BUILDX_BUILDER_NAME"
  fi

  if [[ "$BUILDX_BUILDER_DRIVER" == "docker-container" ]]; then
    docker buildx inspect --bootstrap "$BUILDX_BUILDER_NAME" >/dev/null
  else
    docker buildx inspect "$BUILDX_BUILDER_NAME" >/dev/null
  fi
}

cleanup_legacy_builder() {
  local legacy_builder="kaspa-multiarch"
  if [[ "$BUILDX_BUILDER_NAME" != "$legacy_builder" ]] && docker buildx inspect "$legacy_builder" >/dev/null 2>&1; then
    docker buildx rm "$legacy_builder" >/dev/null 2>&1 || true
  fi
}

resolve_kaspa_tag() {
  if [[ -n "${KASPA_TAG}" ]]; then
    return 0
  fi

  local cargo_version
  cargo_version="$(awk -F'"' '
    /^\[workspace\.package\]/ { in_workspace_package = 1; next }
    /^\[/ { in_workspace_package = 0 }
    in_workspace_package && /^version = "/ { print $2; exit }
  ' "$ROOT_DIR/rusty-kaspa/Cargo.toml" 2>/dev/null || true)"
  if [[ -z "$cargo_version" ]]; then
    cargo_version="$(awk -F'"' '/^version = "/ {print $2; exit}' "$ROOT_DIR/rusty-kaspa/Cargo.toml" 2>/dev/null || true)"
  fi
  if [[ -n "$cargo_version" ]]; then
    KASPA_TAG="v${cargo_version}"
    return 0
  fi

  KASPA_TAG="latest"
}

build_push() {
  local image="$1"
  local dockerfile="$2"
  local context="$3"
  shift 3
  local tag
  local args=()
  for tag in "$@"; do
    args+=(-t "$image:$tag")
  done

  if [[ ${#args[@]} -eq 0 ]]; then
    args+=(-t "$image:latest")
  fi

  local push_args=()
  if [[ "$PUSH_IMAGES" == "1" ]]; then
    push_args+=(--push)
  fi
  docker buildx build \
    --builder "$BUILDX_BUILDER_NAME" \
    --platform "$DOCKER_PLATFORMS" \
    "${push_args[@]}" \
    "${args[@]}" \
    -f "$dockerfile" \
    "$context"
}

print_module_header() {
  local module="$1"
  echo
  echo "=================================================="
  echo "Compiling module: ${module}"
  echo "=================================================="
}

# should_build prueft, ob ein Modul gebaut wird (MODULES leer -> alle).
should_build() {
  local module="$1"
  if [[ -z "$MODULES" ]]; then
    return 0
  fi
  local entry
  local IFS=','
  for entry in $MODULES; do
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == "$module" ]]; then
      return 0
    fi
  done
  return 1
}

require_docker
require_buildx
ensure_buildx_builder
cleanup_legacy_builder

# Docker-Registrierungs-Anmeldung:
#   1) Nicht-interaktiv, wenn KASPA_DOCKER_USER + KASPA_DOCKER_TOKEN gesetzt sind.
#   2) Interaktiv an einem echten Terminal.
#   3) Sonst die via scripts/docker-login.ps1 hinterlegte Anmeldung verwenden.
DOCKER_REGISTRY="${DOCKER_REGISTRY:-docker.io}"

# Push standardmaessig aktiv (Anmeldung wird via scripts/docker-login.ps1 hinterlegt).
# Mit PUSH_IMAGES=0 werden die Images nur lokal gebaut.
PUSH_IMAGES="${PUSH_IMAGES:-1}"

if [[ -n "${KASPA_DOCKER_USER:-}" && -n "${KASPA_DOCKER_TOKEN:-}" ]]; then
  printf '%s' "$KASPA_DOCKER_TOKEN" | docker login --username "$KASPA_DOCKER_USER" --password-stdin "$DOCKER_REGISTRY"
elif [[ -t 0 ]]; then
  docker login
else
  echo "Kein Terminal fuer docker login; nutze die via scripts/docker-login.ps1 hinterlegte Anmeldung." >&2
fi

if [[ "$PUSH_IMAGES" != "1" ]]; then
  echo "Hinweis: PUSH_IMAGES != 1 -> nur lokaler Build, kein Push." >&2
fi

# Keep rusty-kaspa up to date (git pull --ff-only / clone).
# Sync nur, wenn Module aus dem rusty-kaspa Repo gebaut werden.
if should_build "rusty-kaspa" || should_build "kaspa-stratum-bridge"; then
  KASPA_EXTERNAL_SYNC_STRICT=1 KASPA_EXTERNAL_SYNC_RETRIES=4 bash "$ROOT_DIR/scripts/sync-external-repos.sh" "$ROOT_DIR"
fi
resolve_kaspa_tag
echo "Using Rusty Kaspa tag: ${KASPA_TAG}"

# Rusty Kaspa Node
if should_build "rusty-kaspa"; then
  print_module_header "rusty-kaspa"
  build_push "dennitzo/rusty-kaspa" "$ROOT_DIR/rusty-kaspa/docker/Dockerfile.kaspad" "$ROOT_DIR/rusty-kaspa" "$KASPA_TAG"
fi

# Kaspa Stratum Bridge (source from rusty-kaspa repo)
if should_build "kaspa-stratum-bridge"; then
  # Validate the local bridge patch before building or pushing the bridge image.
  git -C "$ROOT_DIR/rusty-kaspa" apply --check "$ROOT_DIR/patches/node-status.patch"
  bridge_dockerfile_dir="$(mktemp -d)"
  trap 'rm -rf "$bridge_dockerfile_dir"' EXIT
  bash "$ROOT_DIR/scripts/generate-bridge-dockerfile.sh" \
    "$ROOT_DIR/rusty-kaspa/docker/Dockerfile.stratum-bridge" \
    "$bridge_dockerfile_dir/Dockerfile"
  print_module_header "kaspa-stratum-bridge"
  push_args=()
  if [[ "$PUSH_IMAGES" == "1" ]]; then
    push_args+=(--push)
  fi
  docker buildx build \
    --builder "$BUILDX_BUILDER_NAME" \
    --platform "$DOCKER_PLATFORMS" \
    --no-cache \
    --build-context "kaspa-dashboard-patch=$ROOT_DIR/patches" \
    "${push_args[@]}" \
    -t "dennitzo/kaspa-stratum-bridge:${KASPA_TAG}" \
    -f "$bridge_dockerfile_dir/Dockerfile" \
    "$ROOT_DIR/rusty-kaspa"
fi

# Node UI/API + Stratum Dashboard
if should_build "kaspa-node-ui"; then
  print_module_header "kaspa-node-ui"
  build_push dennitzo/kaspa-node-ui "$ROOT_DIR/kaspa-node/frontend/Dockerfile" "$ROOT_DIR/kaspa-node/frontend" latest
fi
if should_build "kaspa-node-api"; then
  print_module_header "kaspa-node-api"
  build_push dennitzo/kaspa-node-api "$ROOT_DIR/kaspa-node/api/Dockerfile" "$ROOT_DIR/kaspa-node/api" latest
fi
if should_build "kaspa-stratum-dashboard"; then
  print_module_header "kaspa-stratum-dashboard"
  build_push dennitzo/kaspa-stratum-dashboard "$ROOT_DIR/rusty-kaspa-bridge-dashboard/Dockerfile" "$ROOT_DIR/rusty-kaspa-bridge-dashboard" latest
fi
