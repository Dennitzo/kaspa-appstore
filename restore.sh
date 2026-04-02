#!/usr/bin/env bash
set -euo pipefail

KASPA_SOURCE="/home/umbrel/Kaspa/backup/kaspa-mainnet"
KASPA_DEST="/home/umbrel/umbrel/app-data/kaspa-node/kaspa-mainnet"

docker stop kaspa-node_kaspad_1 || true

mkdir -p "${KASPA_DEST}"
rsync -a --delete "${KASPA_SOURCE}/" "${KASPA_DEST}/"

docker start kaspa-node_kaspad_1 || true

echo "Restore done:"
echo "  ${KASPA_DEST}"
