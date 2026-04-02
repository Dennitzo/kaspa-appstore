#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RETRIES="${KASPA_EXTERNAL_SYNC_RETRIES:-4}"
BACKOFF_BASE_SECS="${KASPA_EXTERNAL_SYNC_BACKOFF_SECS:-2}"
STRICT="${KASPA_EXTERNAL_SYNC_STRICT:-1}"
LOCAL_ONLY_REPOS="${KASPA_EXTERNAL_LOCAL_ONLY_REPOS:-kaspa-explorer-ng,kaspa-socket-server,kaspa-rest-server}"

is_truthy() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_local_only_repo() {
  local dir="$1"
  local entry
  IFS=',' read -r -a entries <<<"$LOCAL_ONLY_REPOS"
  for entry in "${entries[@]}"; do
    [[ "$entry" == "$dir" ]] && return 0
  done
  return 1
}

remove_target_dir() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 0
  fi

  chmod -R u+w "$path" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    rm -rf "$path" 2>/dev/null || true
    [[ ! -e "$path" ]] && return 0
    sleep 0.2
  done
  return 1
}

clone_repo_with_retry() {
  local dir="$1"
  local url="$2"
  local target="$3"
  local attempt sleep_secs

  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    remove_target_dir "$target" || true
    if git clone --depth 1 "$url" "$target"; then
      return 0
    fi
    if ((attempt < RETRIES)); then
      sleep_secs=$((BACKOFF_BASE_SECS * attempt))
      echo "Clone failed for $dir (attempt ${attempt}/${RETRIES}); retrying in ${sleep_secs}s"
      sleep "$sleep_secs"
    fi
  done
  return 1
}

pull_repo_with_retry() {
  local dir="$1"
  local target="$2"
  local attempt sleep_secs upstream remote branch

  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    upstream="$(git -C "$target" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -n "$upstream" && "$upstream" == */* ]]; then
      remote="${upstream%%/*}"
      branch="${upstream#*/}"
      if git -C "$target" pull --ff-only "$remote" "$branch"; then
        return 0
      fi
    elif git -C "$target" pull --ff-only; then
      return 0
    fi
    if ((attempt < RETRIES)); then
      sleep_secs=$((BACKOFF_BASE_SECS * attempt))
      echo "Pull failed for $dir (attempt ${attempt}/${RETRIES}); retrying in ${sleep_secs}s"
      sleep "$sleep_secs"
    fi
  done
  return 1
}

repo_checkout_is_valid() {
  local dir="$1"
  local target="$2"
  case "$dir" in
    k)
      [[ -f "$target/package.json" ]]
      ;;
    k-indexer)
      [[ -f "$target/docker/PROD/Dockerfile.K-transaction-processor" && -f "$target/docker/PROD/Dockerfile.K-webserver" ]]
      ;;
    Kasia)
      [[ -f "$target/package.json" ]]
      ;;
    kasia-indexer)
      [[ -f "$target/Dockerfile" ]]
      ;;
    simply-kaspa-indexer)
      [[ -f "$target/docker/Dockerfile" ]]
      ;;
    rusty-kaspa)
      [[ -f "$target/docker/Dockerfile.kaspad" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

sync_external_repo() {
  local dir="$1"
  local url="$2"
  local target="$ROOT_DIR/$dir"
  local current_url

  # Keep local working copies intact for repos we maintain directly in this store.
  # If missing entirely, they can still be cloned once as a bootstrap.
  if is_local_only_repo "$dir" && [[ -e "$target" ]]; then
    echo "Using local repo $dir (sync skipped)"
    return
  fi

  if [[ -d "$target/.git" ]]; then
    if ! repo_checkout_is_valid "$dir" "$target"; then
      echo "External repo $dir checkout appears incomplete; recloning"
      clone_repo_with_retry "$dir" "$url" "$target"
      return
    fi

    current_url="$(git -C "$target" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$current_url" && "$current_url" != "$url" ]]; then
      echo "External repo remote mismatch for $dir; recloning ($current_url -> $url)"
      clone_repo_with_retry "$dir" "$url" "$target"
      return
    fi

    echo "Updating external repo $dir via git pull --ff-only"
    if pull_repo_with_retry "$dir" "$target"; then
      return
    fi

    if is_truthy "$STRICT"; then
      echo "Failed to update external repo: $dir" >&2
      exit 1
    fi

    echo "Warning: failed to update $dir; continuing with existing checkout" >&2
    return
  fi

  if [[ -e "$target" ]]; then
    echo "External repo $dir exists without .git; recloning"
    remove_target_dir "$target" || true
  fi

  echo "Cloning external repo $dir"
  clone_repo_with_retry "$dir" "$url" "$target"
}

repos=(
  "rusty-kaspa|https://github.com/kaspanet/rusty-kaspa.git"
  "k|https://github.com/thesheepcat/K.git"
  "k-indexer|https://github.com/thesheepcat/K-indexer.git"
  "simply-kaspa-indexer|https://github.com/supertypo/simply-kaspa-indexer.git"
  "Kasia|https://github.com/K-Kluster/Kasia.git"
  "kasia-indexer|https://github.com/K-Kluster/kasia-indexer.git"
)

for entry in "${repos[@]}"; do
  IFS='|' read -r dir url <<<"$entry"
  sync_external_repo "$dir" "$url"
done
