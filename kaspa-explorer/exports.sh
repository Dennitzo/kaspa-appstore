# IP assignments for Kaspa Explorer UI services
export APP_KASPA_EXPLORER_UI_ADDRESS="10.21.24.2"
export APP_KASPA_REST_SERVER_ADDRESS="10.21.24.3"
export APP_KASPA_SOCKET_SERVER_ADDRESS="10.21.24.4"

# Shared Kaspa Database + Node (from kaspa-database app)
export APP_KASPA_DB_ADDRESS="host.docker.internal"
export APP_KASPA_DB_PORT="5432"
export APP_KASPA_DB_NAME="kaspa"
export APP_KASPA_DB_USER="kaspa"
export APP_KASPA_DB_PASSWORD="dbpassword"
export APP_KASPA_NODE_ADDRESS="host.docker.internal"
export APP_KASPA_NODE_PORT="17110"

# For other apps that might need to reach the Explorer services directly
export APP_KASPA_EXPLORER_PORT="8080"
export APP_KASPA_EXPLORER_API_URI="http://${APP_KASPA_REST_SERVER_ADDRESS}:8000"
export APP_KASPA_EXPLORER_API_WS_URI="ws://${APP_KASPA_SOCKET_SERVER_ADDRESS}:8000"
export APP_KASPA_EXPLORER_WS_PORT="8000"
