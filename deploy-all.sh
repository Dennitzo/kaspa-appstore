#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
KASPA_TAG="${KASPA_TAG:-}"
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64}"
BUILDX_BUILDER_NAME="${BUILDX_BUILDER_NAME:-kaspa-amd64}"
BUILDX_BUILDER_DRIVER="${BUILDX_BUILDER_DRIVER:-docker}"

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
    BUILDX_BUILDER_NAME="default"
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
  cargo_version="$(awk -F'"' '/^version = "/ {print $2; exit}' "$ROOT_DIR/rusty-kaspa/Cargo.toml" 2>/dev/null || true)"
  if [[ -n "$cargo_version" ]]; then
    KASPA_TAG="v${cargo_version}"
    return 0
  fi

  KASPA_TAG="v1.1.0"
}

build_push() {
  local image="$1"
  local dockerfile="$2"
  local context="$3"
  docker buildx build \
    --builder "$BUILDX_BUILDER_NAME" \
    --platform "$DOCKER_PLATFORMS" \
    --push \
    -t "$image" \
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

require_docker
require_buildx
ensure_buildx_builder
cleanup_legacy_builder
docker login

# Keep all external source repos updated (git pull --ff-only / clone).
KASPA_EXTERNAL_SYNC_STRICT=1 KASPA_EXTERNAL_SYNC_RETRIES=4 bash "$ROOT_DIR/scripts/sync-external-repos.sh" "$ROOT_DIR"
resolve_kaspa_tag
echo "Using Rusty Kaspa tag: ${KASPA_TAG}"

# K-Social frontend (source from synced k repo)
print_module_header "k-social-web"
build_push dennitzo/k-social-web:latest "$ROOT_DIR/kaspa-k-social/Dockerfile.web" "$ROOT_DIR/k"

# K-indexer services (used by database + K-Social)
print_module_header "k-transaction-processor"
build_push dennitzo/k-transaction-processor:latest "$ROOT_DIR/k-indexer/docker/PROD/Dockerfile.K-transaction-processor" "$ROOT_DIR/k-indexer"
print_module_header "k-webserver"
build_push dennitzo/k-webserver:latest "$ROOT_DIR/k-indexer/docker/PROD/Dockerfile.K-webserver" "$ROOT_DIR/k-indexer"

# Kaspa Database app images
print_module_header "kaspa-database-api"
build_push dennitzo/kaspa-database-api:latest "$ROOT_DIR/kaspa-database/api/Dockerfile" "$ROOT_DIR/kaspa-database/api"
print_module_header "kaspa-database-ui"
build_push dennitzo/kaspa-database-ui:latest "$ROOT_DIR/kaspa-database/frontend/Dockerfile" "$ROOT_DIR/kaspa-database/frontend"

# Explorer + sidecars
print_module_header "kaspa-explorer-ng"
build_push dennitzo/kaspa-explorer-ng:latest "$ROOT_DIR/kaspa-explorer-ng/Dockerfile" "$ROOT_DIR/kaspa-explorer-ng"
print_module_header "kaspa-socket-server"
build_push dennitzo/kaspa-socket-server:latest "$ROOT_DIR/kaspa-socket-server/docker/Dockerfile" "$ROOT_DIR/kaspa-socket-server"
print_module_header "kaspa-rest-server"
build_push dennitzo/kaspa-rest-server:latest "$ROOT_DIR/kaspa-rest-server/Dockerfile" "$ROOT_DIR/kaspa-rest-server"

# Indexers
print_module_header "simply-kaspa-indexer"
build_push dennitzo/simply-kaspa-indexer:latest "$ROOT_DIR/simply-kaspa-indexer/docker/Dockerfile" "$ROOT_DIR/simply-kaspa-indexer"
print_module_header "kasia-indexer"
build_push dennitzo/kasia-indexer:latest "$ROOT_DIR/kasia-indexer/Dockerfile" "$ROOT_DIR/kasia-indexer"

# Kasia web (source from synced Kasia repo)
print_module_header "kasia-web"
build_push dennitzo/kasia-web:latest "$ROOT_DIR/kaspa-kasia/Dockerfile.web" "$ROOT_DIR/Kasia"

# Rusty Kaspa node + stratum bridge (bridge is built from rusty-kaspa repo)
if [[ -d "$ROOT_DIR/kaspa-wasm32-sdk" ]]; then
  rm -rf "$ROOT_DIR/rusty-kaspa/kaspa-wasm32-sdk"
  cp -a "$ROOT_DIR/kaspa-wasm32-sdk" "$ROOT_DIR/rusty-kaspa/kaspa-wasm32-sdk"
fi

print_module_header "rusty-kaspa"
build_push "dennitzo/rusty-kaspa:${KASPA_TAG}" "$ROOT_DIR/rusty-kaspa/docker/Dockerfile.kaspad" "$ROOT_DIR/rusty-kaspa"
print_module_header "kaspa-stratum-bridge"
docker buildx build \
  --builder "$BUILDX_BUILDER_NAME" \
  --platform "$DOCKER_PLATFORMS" \
  --no-cache \
  --push \
  -t "dennitzo/kaspa-stratum-bridge:${KASPA_TAG}" \
  -f "$ROOT_DIR/rusty-kaspa/docker/Dockerfile.stratum-bridge" \
  "$ROOT_DIR/rusty-kaspa"

# Node UI/API + stratum dashboard
print_module_header "kaspa-node-ui"
build_push dennitzo/kaspa-node-ui:latest "$ROOT_DIR/kaspa-node/frontend/Dockerfile" "$ROOT_DIR/kaspa-node/frontend"
print_module_header "kaspa-node-api"
build_push dennitzo/kaspa-node-api:latest "$ROOT_DIR/kaspa-node/api/Dockerfile" "$ROOT_DIR/kaspa-node/api"
print_module_header "kaspa-stratum-dashboard"
build_push dennitzo/kaspa-stratum-dashboard:latest "$ROOT_DIR/rusty-kaspa-bridge-dashboard/Dockerfile" "$ROOT_DIR/rusty-kaspa-bridge-dashboard"
