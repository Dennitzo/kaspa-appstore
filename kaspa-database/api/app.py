import json
import logging
import os
import re
import time
from datetime import datetime, timezone

import psycopg2
from flask import Flask, Response, jsonify, request
from psycopg2.extras import RealDictCursor
import docker

app = Flask(__name__)
app.config["JSON_SORT_KEYS"] = False
logging.basicConfig(level=logging.INFO)
docker_client = docker.from_env()

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

LOG_SERVICES = {
    "kaspa_db": "postgres:17-alpine",
    "simply_kaspa_indexer": "dennitzo/simply-kaspa-indexer",
    "k-transaction-processor": "thesheepcat/k-transaction-processor",
    "kasia-indexer": "dennitzo/kasia-indexer",
}

TABLE_STATS_SQL = """
SELECT
    relname AS table_name,
    COALESCE(n_live_tup, 0)::bigint AS live_rows,
    COALESCE(n_dead_tup, 0)::bigint AS dead_rows,
    COALESCE(seq_scan, 0)::bigint AS seq_scan,
    COALESCE(idx_scan, 0)::bigint AS idx_scan,
    COALESCE(pg_total_relation_size(relid), 0)::bigint AS total_size_bytes
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 6
"""


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if not value:
        raise EnvironmentError(f"Missing required environment variable: {name}")
    return value


def _load_db_config() -> dict:
    return {
        "host": _env("APP_KASPA_DB_ADDRESS"),
        "port": int(_env("APP_KASPA_DB_PORT")),
        "user": _env("APP_KASPA_DB_USER"),
        "password": _env("APP_KASPA_DB_PASSWORD"),
        "dbname": _env("APP_KASPA_DB_NAME"),
        "connect_timeout": 5,
    }


def _convert_table_row(row: dict) -> dict:
    return {
        "table_name": row.get("table_name") or "unknown",
        "live_rows": int(row.get("live_rows", 0)),
        "dead_rows": int(row.get("dead_rows", 0)),
        "seq_scan": int(row.get("seq_scan", 0)),
        "idx_scan": int(row.get("idx_scan", 0)),
        "total_size_bytes": int(row.get("total_size_bytes", 0)),
    }


def _collect_stats() -> dict:
    config = _load_db_config()
    with psycopg2.connect(**config) as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT pg_database_size(current_database())::bigint AS size_bytes")
            db_size = int(cur.fetchone()["size_bytes"] or 0)

            cur.execute(
                "SELECT COUNT(*)::int AS count FROM pg_stat_activity WHERE datname = current_database()"
            )
            connection_count = int(cur.fetchone()["count"] or 0)

            cur.execute(
                "SELECT COUNT(*)::int AS table_count FROM information_schema.tables WHERE table_schema = 'public'"
            )
            table_count = int(cur.fetchone()["table_count"] or 0)

            cur.execute(
                "SELECT EXTRACT(EPOCH FROM now() - pg_postmaster_start_time())::int AS uptime_seconds"
            )
            uptime_seconds = int(cur.fetchone()["uptime_seconds"] or 0)

            cur.execute(TABLE_STATS_SQL)
            table_stats = [_convert_table_row(row) for row in cur.fetchall()]

    total_sampled_rows = sum(row["live_rows"] for row in table_stats)
    total_sampled_size = sum(row["total_size_bytes"] for row in table_stats)
    largest_table = table_stats[0]["table_name"] if table_stats else None

    return {
        "dbSizeBytes": db_size,
        "connectedClients": connection_count,
        "tableCount": table_count,
        "uptimeSeconds": uptime_seconds,
        "tableStats": table_stats,
        "tableTotals": {
            "liveRows": total_sampled_rows,
            "totalSizeBytes": total_sampled_size,
        },
        "largestTable": largest_table,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

def _resolve_container(service: str):
    project = os.environ.get("APP_COMPOSE_PROJECT") or os.environ.get("APP_ID") or "kaspa-database"
    filters = {
        "label": [
            f"com.docker.compose.project={project}",
            f"com.docker.compose.service={service}",
        ]
    }
    containers = docker_client.containers.list(filters=filters)
    if containers:
        return containers[0]
    raise LookupError(f"Container not found for service: {service}")

def _strip_ansi(value: str) -> str:
    return ANSI_ESCAPE_RE.sub("", value)



@app.after_request
def do_not_cache(response):
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers[
        "Access-Control-Allow-Headers"
    ] = "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range"
    response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    return response


@app.route("/api/status", methods=["GET"])
def status():
    try:
        payload = _collect_stats()
        return jsonify(payload)
    except Exception as exc:  # pragma: no cover - external dependency
        app.logger.exception("Unable to gather indexer metrics", exc_info=exc)
        return jsonify({"error": "Unable to collect indexer metrics"}), 503


@app.route("/api/status/stream", methods=["GET"])
def status_stream():
    interval = request.args.get("interval", "10")
    try:
        interval_seconds = max(5, min(int(interval), 60))
    except ValueError:
        interval_seconds = 10

    def generate():
        while True:
            try:
                payload = _collect_stats()
                yield f"data: {json.dumps(payload)}\n\n"
            except Exception as exc:  # pragma: no cover - external dependency
                app.logger.exception("Unable to gather indexer metrics", exc_info=exc)
                payload = json.dumps({"error": "Unable to collect indexer metrics"})
                yield f"event: error\ndata: {payload}\n\n"
            try:
                time.sleep(interval_seconds)
            except GeneratorExit:
                break

    headers = {
        "Cache-Control": "no-cache",
        "Content-Type": "text/event-stream",
        "X-Accel-Buffering": "no",
    }
    return Response(stream_with_context(generate()), headers=headers)


@app.route("/api/healthz", methods=["GET"])
def healthz():  # pragma: no cover - trivial endpoint
    return jsonify({"status": "ok"})


@app.route("/api/logs/<service>", methods=["GET"])
def logs(service: str):
    if service not in LOG_SERVICES:
        return jsonify({"error": "Unknown service"}), 404

    try:
        container = _resolve_container(service)
    except Exception as exc:
        app.logger.exception("Unable to resolve container", exc_info=exc)
        return jsonify({"error": "Unable to locate container"}), 404

    tail = request.args.get("tail", "200")
    since = request.args.get("since")
    try:
        tail_count = max(10, min(int(tail), 500))
    except ValueError:
        tail_count = 200
    try:
        since_value = int(since) if since else None
    except ValueError:
        since_value = None

    try:
        raw_logs = container.logs(stream=False, follow=False, tail=tail_count, since=since_value)
    except Exception as exc:
        app.logger.exception("Log fetch error", exc_info=exc)
        return jsonify({"error": "Unable to fetch logs"}), 503

    text = raw_logs.decode("utf-8", errors="replace")
    lines = [_strip_ansi(line) for line in text.splitlines()]
    payload = "\n".join(line for line in lines if line)
    return Response(payload, mimetype="text/plain")



if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
