#!/usr/bin/env python3
"""Single-user body-weight sync API using only the Python standard library."""

from __future__ import annotations

import hmac
import json
import logging
import os
import sqlite3
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID


HOST = os.environ.get("BODY_WEIGHT_API_HOST", "127.0.0.1")
PORT = int(os.environ.get("BODY_WEIGHT_API_PORT", "8897"))
DATABASE_PATH = Path(os.environ.get("BODY_WEIGHT_DATABASE_PATH", "/var/lib/body-weight-api/body-weight.sqlite3"))
API_TOKEN = os.environ.get("BODY_WEIGHT_API_TOKEN", "")
MAX_BODY_BYTES = 1_048_576

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("body-weight-api")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError(f"{field} must be an ISO-8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(f"{field} must be a valid ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def canonical_timestamp(value: Any, field: str) -> str:
    return parse_timestamp(value, field).isoformat().replace("+00:00", "Z")


def validate_entry(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("each entry must be an object")

    try:
        entry_id = str(UUID(str(raw["id"])))
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("id must be a UUID") from error

    try:
        weight = float(raw["weightKG"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("weightKG must be a number") from error
    if not 20 <= weight <= 500:
        raise ValueError("weightKG must be between 20 and 500")

    source = raw.get("source")
    if source not in {"manual", "photo", "voice"}:
        raise ValueError("source must be manual, photo, or voice")

    original_text = raw.get("originalText", "")
    if not isinstance(original_text, str) or len(original_text) > 2_000:
        raise ValueError("originalText must be a string of at most 2000 characters")

    is_deleted = raw.get("isDeleted", False)
    if not isinstance(is_deleted, bool):
        raise ValueError("isDeleted must be a boolean")

    return {
        "id": entry_id,
        "weightKG": weight,
        "recordedAt": canonical_timestamp(raw.get("recordedAt"), "recordedAt"),
        "createdAt": canonical_timestamp(raw.get("createdAt"), "createdAt"),
        "updatedAt": canonical_timestamp(raw.get("updatedAt"), "updatedAt"),
        "source": source,
        "originalText": original_text,
        "isDeleted": is_deleted,
    }


class WeightRepository:
    def __init__(self, database_path: Path) -> None:
        self.database_path = database_path
        database_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS weight_entries (
                    id TEXT PRIMARY KEY,
                    weight_kg REAL NOT NULL,
                    recorded_at TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    original_text TEXT NOT NULL DEFAULT '',
                    is_deleted INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_weight_entries_updated_at ON weight_entries(updated_at)"
            )

    def synchronize(self, raw_entries: list[Any]) -> list[dict[str, Any]]:
        entries = [validate_entry(raw) for raw in raw_entries]
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            for entry in entries:
                existing = connection.execute(
                    "SELECT updated_at FROM weight_entries WHERE id = ?", (entry["id"],)
                ).fetchone()
                if existing and parse_timestamp(existing["updated_at"], "updatedAt") >= parse_timestamp(
                    entry["updatedAt"], "updatedAt"
                ):
                    continue

                connection.execute(
                    """
                    INSERT INTO weight_entries (
                        id, weight_kg, recorded_at, created_at, updated_at,
                        source, original_text, is_deleted
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        weight_kg = excluded.weight_kg,
                        recorded_at = excluded.recorded_at,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        source = excluded.source,
                        original_text = excluded.original_text,
                        is_deleted = excluded.is_deleted
                    """,
                    (
                        entry["id"], entry["weightKG"], entry["recordedAt"], entry["createdAt"],
                        entry["updatedAt"], entry["source"], entry["originalText"], int(entry["isDeleted"]),
                    ),
                )
            rows = connection.execute(
                """
                SELECT id, weight_kg, recorded_at, created_at, updated_at,
                       source, original_text, is_deleted
                FROM weight_entries
                ORDER BY recorded_at ASC, id ASC
                """
            ).fetchall()

        return [
            {
                "id": row["id"],
                "weightKG": row["weight_kg"],
                "recordedAt": row["recorded_at"],
                "createdAt": row["created_at"],
                "updatedAt": row["updated_at"],
                "source": row["source"],
                "originalText": row["original_text"],
                "isDeleted": bool(row["is_deleted"]),
            }
            for row in rows
        ]


class APIHandler(BaseHTTPRequestHandler):
    repository: WeightRepository
    api_token: str
    server_version = "BodyWeightAPI/1.0"

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {self.api_token}"
        return bool(self.api_token) and hmac.compare_digest(supplied, expected)

    def do_GET(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path == "/health":
            self._send_json(200, {"status": "ok", "serverTime": utc_now()})
            return
        self._send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path != "/v1/sync":
            self._send_json(404, {"error": "not_found"})
            return
        if not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": "invalid_content_length"})
            return
        if content_length <= 0 or content_length > MAX_BODY_BYTES:
            self._send_json(413, {"error": "invalid_body_size"})
            return

        try:
            payload = json.loads(self.rfile.read(content_length))
            raw_entries = payload.get("entries") if isinstance(payload, dict) else None
            if not isinstance(raw_entries, list) or len(raw_entries) > 10_000:
                raise ValueError("entries must be an array with at most 10000 items")
            entries = self.repository.synchronize(raw_entries)
            self._send_json(200, {"entries": entries, "serverTime": utc_now()})
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self._send_json(400, {"error": "invalid_request", "message": str(error)})
        except Exception:
            logger.exception("Unhandled sync error")
            self._send_json(500, {"error": "internal_error"})

    def log_message(self, message_format: str, *args: Any) -> None:
        logger.info("%s %s", self.address_string(), message_format % args)


def run() -> None:
    if not API_TOKEN:
        raise RuntimeError("BODY_WEIGHT_API_TOKEN is required")
    repository = WeightRepository(DATABASE_PATH)
    APIHandler.repository = repository
    APIHandler.api_token = API_TOKEN
    server = ThreadingHTTPServer((HOST, PORT), APIHandler)
    logger.info("Listening on http://%s:%s", HOST, PORT)
    server.serve_forever()


if __name__ == "__main__":
    run()
