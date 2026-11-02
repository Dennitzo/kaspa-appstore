#!/usr/bin/env bash
# Legt die Docker-Registrierungsdaten (Docker Hub) einmalig sicher im
# Docker-Anmeldespeicher ab, damit deploy-all.sh die Images pushen kann.
#
# Verwendung:
#   bash scripts/docker-login.sh
#   bash scripts/docker-login.sh docker.io mein-benutzername
#
# Der Token wird interaktiv abgefragt (nicht angezeigt, nirgends gespeichert).
# Empfohlen wird ein Docker-Hub-Access-Token, nicht das Konto-Passwort:
#   Docker Hub -> Account Settings -> Security -> New Access Token
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${1:-${REGISTRY:-docker.io}}"
USERNAME="${2:-${DOCKER_USERNAME:-}}"

if ! docker info >/dev/null 2>&1; then
  echo "Docker ist nicht erreichbar. Bitte Docker starten und erneut ausfuehren." >&2
  exit 1
fi

if [[ -z "$USERNAME" ]]; then
  read -rp "Docker-Hub Benutzername: " USERNAME
fi

echo "Hinweis: Bitte einen Access-Token verwenden, nicht das Konto-Passwort." >&2
read -rsp "Zugangs-Token (Eingabe wird nicht angezeigt): " TOKEN
echo

printf '%s' "$TOKEN" | docker login --username "$USERNAME" --password-stdin "$REGISTRY"
TOKEN=

echo "Anmeldung erfolgreich. Die Zugangsdaten liegen im Docker-Anmeldespeicher." >&2
echo "Naechster Schritt (Build mit Push):"
echo "  PUSH_IMAGES=1 bash deploy-all.sh"
