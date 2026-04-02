import json
import logging
import os
import re
from datetime import datetime, timezone

import docker
from flask import Flask, Response, jsonify, request

app = Flask(__name__)
app.config["JSON_SORT_KEYS"] = False
logging.basicConfig(level=logging.INFO)

docker_client = docker.from_env()

PROJECT_NAME = os.environ.get("APP_COMPOSE_PROJECT", "kaspa-node")
KASPAD_SERVICE = os.environ.get("APP_KASPAD_SERVICE", "kaspad")
KNOWN_SERVICES = {
    "kaspad": "dennitzo/rusty-kaspa",
    "kaspa-api": "kaspa-node-api",
    "frontend": "kaspa-node-ui",
}


def _resolve_container(service: str):
    filters = {
        "label": [
            f"com.docker.compose.project={PROJECT_NAME}",
            f"com.docker.compose.service={service}",
        ]
    }
    containers = docker_client.containers.list(filters=filters)
    if containers:
        return containers[0]
    raise LookupError(f"Container not found for service: {service}")


def _container_uptime_seconds(container) -> int:
    started_at = container.attrs.get("State", {}).get("StartedAt")
    if not started_at:
        return 0
    try:
        started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
    except ValueError:
        return 0
    return int((datetime.now(timezone.utc) - started).total_seconds())


def _container_appdir_bytes(container, app_dir: str = "/app/data") -> int:
    try:
        result = container.exec_run(["du", "-sb", app_dir], stdout=True, stderr=True)
    except Exception:
        return 0
    if result.exit_code != 0:
        return 0
    output = result.output.decode("utf-8", errors="replace").strip()
    if not output:
        return 0
    size_str = output.split()[0]
    try:
        return int(size_str)
    except ValueError:
        return 0


def _parse_log_line(line: str) -> dict:
    if not line:
        return {"message": "", "level": "--", "timestamp": "--", "source": "--"}
    if "[" in line and "]" in line:
        prefix, rest = line.split("[", 1)
        level_part, message = rest.split("]", 1)
        timestamp = prefix.strip()
        level = level_part.strip()
        return {
            "message": message.strip(),
            "level": level or "--",
            "timestamp": timestamp or "--",
        }
    return {"message": line, "level": "--", "timestamp": "--"}


@app.after_request
def do_not_cache(response):
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Headers"] = (
        "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range"
    )
    response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    return response


@app.route("/api/status", methods=["GET"])
def status():
    try:
        container = _resolve_container(KASPAD_SERVICE)
        state = container.attrs.get("State", {})
        config = container.attrs.get("Config", {})
        cmd = " ".join(config.get("Cmd") or [])
        log_tail_raw = container.logs(tail=10).decode("utf-8", errors="replace")
        log_tail = [
            _parse_log_line(line.strip()) for line in log_tail_raw.splitlines() if line.strip()
        ]
        log_tail.reverse()
        kaspad_version = None
        for line in reversed(log_tail_raw.splitlines()):
            match = re.search(r"\bkaspad\s+v([^\s]+)", line)
            if match:
                kaspad_version = match.group(1)
                break
        network = "mainnet"
        if re.search(r"--testnet(=\\S+)?", cmd):
            network = "testnet"
        elif re.search(r"--devnet(=\\S+)?", cmd):
            network = "devnet"
        elif re.search(r"--simnet(=\\S+)?", cmd):
            network = "simnet"

        payload = {
            "status": state.get("Status", "unknown"),
            "image": config.get("Image", "unknown"),
            "uptimeSeconds": _container_uptime_seconds(container),
            "appDir": "/app/data",
            "appDirSizeBytes": _container_appdir_bytes(container),
            "utxoIndexEnabled": "--utxoindex" in cmd,
            "network": network,
            "logTail": log_tail,
            "kaspadVersion": kaspad_version,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        return jsonify(payload)
    except Exception as exc:  # pragma: no cover - external dependency
        app.logger.exception("Unable to gather node status", exc_info=exc)
        return jsonify({"error": "Unable to collect node status"}), 503


@app.route("/api/logs/<service>", methods=["GET"])
def logs(service: str):
    if service not in KNOWN_SERVICES:
        return jsonify({"error": "Unknown service"}), 404

    try:
        container = _resolve_container(service)
    except Exception as exc:
        app.logger.exception("Unable to resolve container", exc_info=exc)
        return jsonify({"error": "Unable to locate container"}), 404

    tail = request.args.get("tail", "200")
    try:
        tail_count = max(10, min(int(tail), 500))
    except ValueError:
        tail_count = 200

    try:
        raw_logs = container.logs(stream=False, follow=False, tail=tail_count)
    except Exception as exc:
        app.logger.exception("Log fetch error", exc_info=exc)
        return jsonify({"error": "Unable to fetch logs"}), 503

    text = raw_logs.decode("utf-8", errors="replace")
    payload = "\n".join(line for line in text.splitlines() if line.strip())
    return Response(payload, mimetype="text/plain")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
