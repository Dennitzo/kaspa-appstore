# Kaspa Stratum Bridge export variables
APP_KASPA_STRATUM_KASPAD_ADDRESS="${APP_KASPA_STRATUM_KASPAD_ADDRESS:-host.docker.internal:16110}"

mkdir -p "${EXPORTS_APP_DIR}" "${EXPORTS_APP_DIR}/bridge-data"
chmod -R 777 "${EXPORTS_APP_DIR}/bridge-data"

CONFIG_PATH="${EXPORTS_APP_DIR}/config.yaml"
if [ ! -f "${CONFIG_PATH}" ]; then
  cat > "${CONFIG_PATH}" <<CONFIG
kaspad_address: "${APP_KASPA_STRATUM_KASPAD_ADDRESS}"
print_stats: true
coinbase_tag_suffix: "Umbrel"

instances:
  - stratum_port: ":5555"
    min_share_diff: 512
    prom_port: ":2114"
    log_to_file: false
    var_diff: true
CONFIG
fi

if ! grep -q '^coinbase_tag_suffix:' "${CONFIG_PATH}"; then
  echo 'coinbase_tag_suffix: "Umbrel"' >> "${CONFIG_PATH}"
fi
