#!/usr/bin/env python3
"""Multi-user body-weight sync API using only the Python standard library."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID, uuid4


HOST = os.environ.get("BODY_WEIGHT_API_HOST", "127.0.0.1")
PORT = int(os.environ.get("BODY_WEIGHT_API_PORT", "8897"))
DATABASE_PATH = Path(os.environ.get("BODY_WEIGHT_DATABASE_PATH", "/var/lib/body-weight-api/body-weight.sqlite3"))
PHOTO_DIRECTORY = Path(os.environ.get("BODY_WEIGHT_PHOTO_PATH", "/var/lib/body-weight-api/photos"))
LEGACY_API_TOKEN = os.environ.get("BODY_WEIGHT_API_TOKEN", "")
REGISTRATION_CODE = os.environ.get("BODY_WEIGHT_REGISTRATION_CODE", LEGACY_API_TOKEN)
SESSION_DAYS = int(os.environ.get("BODY_WEIGHT_SESSION_DAYS", "180"))
MAX_BODY_BYTES = 1_048_576
MAX_PHOTO_BYTES = 12 * 1_048_576
PASSWORD_ITERATIONS = 600_000
LEGACY_USER_ID = "00000000-0000-0000-0000-000000000000"
USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9_.-]{3,32}$")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("body-weight-api")


def utc_now_datetime() -> datetime:
    return datetime.now(timezone.utc)


def format_timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def utc_now() -> str:
    return format_timestamp(utc_now_datetime())


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
    return format_timestamp(parse_timestamp(value, field))


def normalize_username(username: Any) -> tuple[str, str]:
    if not isinstance(username, str):
        raise ValueError("username must be a string")
    display_name = username.strip()
    if not USERNAME_PATTERN.fullmatch(display_name):
        raise ValueError("username must be 3-32 letters, numbers, dots, underscores, or hyphens")
    return display_name, display_name.casefold()


def validate_password(password: Any) -> str:
    if not isinstance(password, str) or not 8 <= len(password) <= 128:
        raise ValueError("password must contain 8-128 characters")
    return password


def password_digest(password: str, salt: bytes, iterations: int = PASSWORD_ITERATIONS) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)


def token_digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


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


class UsernameTakenError(Exception):
    pass


class InvalidCredentialsError(Exception):
    pass


class WeightRepository:
    def __init__(
        self,
        database_path: Path,
        photo_directory: Path | None = None,
        session_days: int = SESSION_DAYS,
    ) -> None:
        self.database_path = database_path
        self.photo_directory = photo_directory or database_path.parent / "photos"
        self.session_days = session_days
        database_path.parent.mkdir(parents=True, exist_ok=True)
        self.photo_directory.mkdir(parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    @staticmethod
    def _create_weight_table(connection: sqlite3.Connection) -> None:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS weight_entries (
                user_id TEXT NOT NULL,
                id TEXT NOT NULL,
                weight_kg REAL NOT NULL,
                recorded_at TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                source TEXT NOT NULL,
                original_text TEXT NOT NULL DEFAULT '',
                is_deleted INTEGER NOT NULL DEFAULT 0,
                photo_updated_at TEXT,
                PRIMARY KEY (user_id, id)
            )
            """
        )

    def _initialize(self) -> None:
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY,
                    username TEXT NOT NULL,
                    username_key TEXT NOT NULL UNIQUE,
                    password_salt BLOB NOT NULL,
                    password_hash BLOB NOT NULL,
                    password_iterations INTEGER NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL
                )
                """
            )

            existing_table = connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'weight_entries'"
            ).fetchone()
            if not existing_table:
                self._create_weight_table(connection)
            else:
                columns = {
                    row["name"] for row in connection.execute("PRAGMA table_info(weight_entries)").fetchall()
                }
                if "user_id" not in columns:
                    connection.execute("ALTER TABLE weight_entries RENAME TO legacy_weight_entries")
                    self._create_weight_table(connection)
                    photo_value = "photo_updated_at" if "photo_updated_at" in columns else "NULL"
                    connection.execute(
                        f"""
                        INSERT INTO weight_entries (
                            user_id, id, weight_kg, recorded_at, created_at, updated_at,
                            source, original_text, is_deleted, photo_updated_at
                        )
                        SELECT ?, id, weight_kg, recorded_at, created_at, updated_at,
                               source, original_text, is_deleted, {photo_value}
                        FROM legacy_weight_entries
                        """,
                        (LEGACY_USER_ID,),
                    )
                    connection.execute("DROP TABLE legacy_weight_entries")
                elif "photo_updated_at" not in columns:
                    connection.execute("ALTER TABLE weight_entries ADD COLUMN photo_updated_at TEXT")

            connection.execute(
                "CREATE INDEX IF NOT EXISTS idx_weight_entries_user_updated ON weight_entries(user_id, updated_at)"
            )
            connection.execute("CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id)")
            connection.execute("CREATE INDEX IF NOT EXISTS idx_sessions_expiry ON sessions(expires_at)")

    @staticmethod
    def _user_payload(row: sqlite3.Row) -> dict[str, str]:
        return {"id": row["id"], "username": row["username"]}

    def _issue_session(self, connection: sqlite3.Connection, user_id: str) -> str:
        token = secrets.token_urlsafe(32)
        now = utc_now_datetime()
        connection.execute("DELETE FROM sessions WHERE expires_at <= ?", (format_timestamp(now),))
        connection.execute(
            "INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
            (
                token_digest(token), user_id, format_timestamp(now),
                format_timestamp(now + timedelta(days=self.session_days)),
            ),
        )
        return token

    def register(self, username: Any, password: Any) -> tuple[dict[str, str], str, bool]:
        display_name, username_key = normalize_username(username)
        valid_password = validate_password(password)
        salt = secrets.token_bytes(16)
        digest = password_digest(valid_password, salt)
        user_id = str(uuid4())

        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if connection.execute(
                "SELECT 1 FROM users WHERE username_key = ?", (username_key,)
            ).fetchone():
                raise UsernameTakenError
            claimed_legacy_data = connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0
            connection.execute(
                """
                INSERT INTO users (
                    id, username, username_key, password_salt, password_hash,
                    password_iterations, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (user_id, display_name, username_key, salt, digest, PASSWORD_ITERATIONS, utc_now()),
            )
            if claimed_legacy_data:
                connection.execute(
                    "UPDATE weight_entries SET user_id = ? WHERE user_id = ?",
                    (user_id, LEGACY_USER_ID),
                )
            token = self._issue_session(connection, user_id)

        if claimed_legacy_data:
            self._claim_legacy_photos(user_id)
        return {"id": user_id, "username": display_name}, token, claimed_legacy_data

    def login(self, username: Any, password: Any) -> tuple[dict[str, str], str]:
        _, username_key = normalize_username(username)
        valid_password = validate_password(password)
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT id, username, password_salt, password_hash, password_iterations
                FROM users WHERE username_key = ?
                """,
                (username_key,),
            ).fetchone()
            if not row:
                password_digest(valid_password, b"\0" * 16)
                raise InvalidCredentialsError
            candidate = password_digest(valid_password, row["password_salt"], row["password_iterations"])
            if not hmac.compare_digest(candidate, row["password_hash"]):
                raise InvalidCredentialsError
            token = self._issue_session(connection, row["id"])
            return self._user_payload(row), token

    def authenticate(self, token: str) -> dict[str, str] | None:
        if not token:
            return None
        now = utc_now_datetime()
        digest = token_digest(token)
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT users.id, users.username, sessions.expires_at
                FROM sessions JOIN users ON users.id = sessions.user_id
                WHERE sessions.token_hash = ?
                """,
                (digest,),
            ).fetchone()
            if not row:
                return None
            if parse_timestamp(row["expires_at"], "expiresAt") <= now:
                connection.execute("DELETE FROM sessions WHERE token_hash = ?", (digest,))
                return None
            return self._user_payload(row)

    def logout(self, token: str) -> None:
        if token:
            with self._connect() as connection:
                connection.execute("DELETE FROM sessions WHERE token_hash = ?", (token_digest(token),))

    def has_registered_users(self) -> bool:
        with self._connect() as connection:
            return connection.execute("SELECT 1 FROM users LIMIT 1").fetchone() is not None

    def synchronize(self, user_id: str, raw_entries: list[Any]) -> list[dict[str, Any]]:
        entries = [validate_entry(raw) for raw in raw_entries]
        with self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            for entry in entries:
                existing = connection.execute(
                    "SELECT updated_at FROM weight_entries WHERE user_id = ? AND id = ?",
                    (user_id, entry["id"]),
                ).fetchone()
                if existing and parse_timestamp(existing["updated_at"], "updatedAt") >= parse_timestamp(
                    entry["updatedAt"], "updatedAt"
                ):
                    continue
                connection.execute(
                    """
                    INSERT INTO weight_entries (
                        user_id, id, weight_kg, recorded_at, created_at, updated_at,
                        source, original_text, is_deleted
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(user_id, id) DO UPDATE SET
                        weight_kg = excluded.weight_kg,
                        recorded_at = excluded.recorded_at,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        source = excluded.source,
                        original_text = excluded.original_text,
                        is_deleted = excluded.is_deleted
                    """,
                    (
                        user_id, entry["id"], entry["weightKG"], entry["recordedAt"],
                        entry["createdAt"], entry["updatedAt"], entry["source"],
                        entry["originalText"], int(entry["isDeleted"]),
                    ),
                )
            deleted_photo_ids = [
                row["id"] for row in connection.execute(
                    """
                    SELECT id FROM weight_entries
                    WHERE user_id = ? AND is_deleted = 1 AND photo_updated_at IS NOT NULL
                    """,
                    (user_id,),
                ).fetchall()
            ]
            if deleted_photo_ids:
                connection.executemany(
                    "UPDATE weight_entries SET photo_updated_at = NULL WHERE user_id = ? AND id = ?",
                    [(user_id, entry_id) for entry_id in deleted_photo_ids],
                )
            rows = connection.execute(
                """
                SELECT id, weight_kg, recorded_at, created_at, updated_at,
                       source, original_text, is_deleted, photo_updated_at
                FROM weight_entries WHERE user_id = ?
                ORDER BY recorded_at ASC, id ASC
                """,
                (user_id,),
            ).fetchall()

        for entry_id in deleted_photo_ids:
            self.photo_path(user_id, entry_id).unlink(missing_ok=True)
        return [
            {
                "id": row["id"], "weightKG": row["weight_kg"],
                "recordedAt": row["recorded_at"], "createdAt": row["created_at"],
                "updatedAt": row["updated_at"], "source": row["source"],
                "originalText": row["original_text"], "isDeleted": bool(row["is_deleted"]),
                "photoUpdatedAt": row["photo_updated_at"],
            }
            for row in rows
        ]

    def photo_path(self, user_id: str, entry_id: str) -> Path:
        canonical_id = str(UUID(entry_id))
        if user_id == LEGACY_USER_ID:
            return self.photo_directory / f"{canonical_id}.jpg"
        user_directory = self.photo_directory / str(UUID(user_id))
        user_directory.mkdir(parents=True, exist_ok=True)
        return user_directory / f"{canonical_id}.jpg"

    def _claim_legacy_photos(self, user_id: str) -> None:
        destination_directory = self.photo_directory / str(UUID(user_id))
        destination_directory.mkdir(parents=True, exist_ok=True)
        for source in self.photo_directory.glob("*.jpg"):
            destination = destination_directory / source.name
            if not destination.exists():
                source.replace(destination)
            else:
                source.unlink(missing_ok=True)

    def get_photo(self, user_id: str, entry_id: str) -> tuple[Path, str] | None:
        canonical_id = str(UUID(entry_id))
        with self._connect() as connection:
            row = connection.execute(
                "SELECT is_deleted, photo_updated_at FROM weight_entries WHERE user_id = ? AND id = ?",
                (user_id, canonical_id),
            ).fetchone()
        path = self.photo_path(user_id, canonical_id)
        if not row or row["is_deleted"] or not row["photo_updated_at"] or not path.is_file():
            return None
        return path, row["photo_updated_at"]

    def save_photo(self, user_id: str, entry_id: str, data: bytes, updated_at: str) -> str:
        canonical_id = str(UUID(entry_id))
        canonical_updated_at = canonical_timestamp(updated_at, "X-Photo-Updated-At")
        with self._connect() as connection:
            row = connection.execute(
                "SELECT is_deleted, photo_updated_at FROM weight_entries WHERE user_id = ? AND id = ?",
                (user_id, canonical_id),
            ).fetchone()
            if not row or row["is_deleted"]:
                raise LookupError("weight entry was not found")
            existing_timestamp = row["photo_updated_at"]
            if existing_timestamp and parse_timestamp(
                existing_timestamp, "photoUpdatedAt"
            ) > parse_timestamp(canonical_updated_at, "photoUpdatedAt"):
                return existing_timestamp

            destination = self.photo_path(user_id, canonical_id)
            temporary = destination.with_suffix(".jpg.tmp")
            try:
                temporary.write_bytes(data)
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
            connection.execute(
                "UPDATE weight_entries SET photo_updated_at = ? WHERE user_id = ? AND id = ?",
                (canonical_updated_at, user_id, canonical_id),
            )
        return canonical_updated_at


class APIHandler(BaseHTTPRequestHandler):
    repository: WeightRepository
    registration_code: str
    legacy_api_token: str
    server_version = "BodyWeightAPI/2.0"

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict[str, Any]:
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("invalid content length") from error
        if content_length <= 0 or content_length > MAX_BODY_BYTES:
            raise ValueError("invalid body size")
        payload = json.loads(self.rfile.read(content_length))
        if not isinstance(payload, dict):
            raise ValueError("body must be a JSON object")
        return payload

    def _bearer_token(self) -> str:
        supplied = self.headers.get("Authorization", "")
        return supplied[7:] if supplied.startswith("Bearer ") else ""

    def _authenticated_user(self) -> dict[str, str] | None:
        token = self._bearer_token()
        user = self.repository.authenticate(token)
        if user:
            return user
        if (
            self.legacy_api_token
            and not self.repository.has_registered_users()
            and hmac.compare_digest(token, self.legacy_api_token)
        ):
            return {"id": LEGACY_USER_ID, "username": "legacy"}
        return None

    def _photo_entry_id(self, path: str) -> str | None:
        prefix = "/v1/photos/"
        if not path.startswith(prefix):
            return None
        candidate = path[len(prefix):]
        if not candidate or "/" in candidate:
            return None
        try:
            return str(UUID(candidate))
        except ValueError:
            return None

    def do_GET(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path == "/health":
            self._send_json(200, {"status": "ok", "serverTime": utc_now(), "apiVersion": 2})
            return
        if path == "/v1/auth/me":
            user = self._authenticated_user()
            if not user or user["id"] == LEGACY_USER_ID:
                self._send_json(401, {"error": "unauthorized"})
                return
            self._send_json(200, {"user": user})
            return
        entry_id = self._photo_entry_id(path)
        if entry_id:
            user = self._authenticated_user()
            if not user:
                self._send_json(401, {"error": "unauthorized"})
                return
            photo = self.repository.get_photo(user["id"], entry_id)
            if not photo:
                self._send_json(404, {"error": "photo_not_found"})
                return
            photo_path, updated_at = photo
            body = photo_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Photo-Updated-At", updated_at)
            self.send_header("Cache-Control", "private, no-cache")
            self.end_headers()
            self.wfile.write(body)
            return
        self._send_json(404, {"error": "not_found"})

    def do_PUT(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/") or "/"
        entry_id = self._photo_entry_id(path)
        if not entry_id:
            self._send_json(404, {"error": "not_found"})
            return
        user = self._authenticated_user()
        if not user:
            self._send_json(401, {"error": "unauthorized"})
            return
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, {"error": "invalid_content_length"})
            return
        if content_length <= 0 or content_length > MAX_PHOTO_BYTES:
            self._send_json(413, {"error": "invalid_photo_size"})
            return
        updated_at = self.headers.get("X-Photo-Updated-At")
        if not updated_at:
            self._send_json(400, {"error": "missing_photo_updated_at"})
            return
        data = self.rfile.read(content_length)
        if len(data) != content_length or not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
            self._send_json(400, {"error": "invalid_jpeg"})
            return
        try:
            saved_at = self.repository.save_photo(user["id"], entry_id, data, updated_at)
            self._send_json(200, {"id": entry_id, "photoUpdatedAt": saved_at})
        except LookupError:
            self._send_json(404, {"error": "weight_entry_not_found"})
        except ValueError as error:
            self._send_json(400, {"error": "invalid_request", "message": str(error)})
        except Exception:
            logger.exception("Unhandled photo upload error")
            self._send_json(500, {"error": "internal_error"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlsplit(self.path).path.rstrip("/") or "/"
        if path == "/v1/auth/register":
            self._register()
            return
        if path == "/v1/auth/login":
            self._login()
            return
        if path == "/v1/auth/logout":
            token = self._bearer_token()
            if not self.repository.authenticate(token):
                self._send_json(401, {"error": "unauthorized"})
                return
            self.repository.logout(token)
            self._send_json(200, {"status": "ok"})
            return
        if path != "/v1/sync":
            self._send_json(404, {"error": "not_found"})
            return

        user = self._authenticated_user()
        if not user:
            self._send_json(401, {"error": "unauthorized"})
            return
        try:
            payload = self._read_json()
            raw_entries = payload.get("entries")
            if not isinstance(raw_entries, list) or len(raw_entries) > 10_000:
                raise ValueError("entries must be an array with at most 10000 items")
            entries = self.repository.synchronize(user["id"], raw_entries)
            self._send_json(200, {"entries": entries, "serverTime": utc_now()})
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self._send_json(400, {"error": "invalid_request", "message": str(error)})
        except Exception:
            logger.exception("Unhandled sync error")
            self._send_json(500, {"error": "internal_error"})

    def _register(self) -> None:
        try:
            payload = self._read_json()
            supplied_code = payload.get("registrationCode", "")
            if not isinstance(supplied_code, str) or not hmac.compare_digest(
                supplied_code, self.registration_code
            ):
                self._send_json(403, {"error": "invalid_registration_code"})
                return
            user, token, claimed = self.repository.register(payload.get("username"), payload.get("password"))
            self._send_json(201, {"token": token, "user": user, "claimedLegacyData": claimed})
        except UsernameTakenError:
            self._send_json(409, {"error": "username_taken"})
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            self._send_json(400, {"error": "invalid_request", "message": str(error)})
        except Exception:
            logger.exception("Unhandled registration error")
            self._send_json(500, {"error": "internal_error"})

    def _login(self) -> None:
        try:
            payload = self._read_json()
            user, token = self.repository.login(payload.get("username"), payload.get("password"))
            self._send_json(200, {"token": token, "user": user, "claimedLegacyData": False})
        except (InvalidCredentialsError, ValueError):
            self._send_json(401, {"error": "invalid_credentials"})
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            self._send_json(400, {"error": "invalid_request", "message": str(error)})
        except Exception:
            logger.exception("Unhandled login error")
            self._send_json(500, {"error": "internal_error"})

    def log_message(self, message_format: str, *args: Any) -> None:
        logger.info("%s %s", self.address_string(), message_format % args)


def run() -> None:
    if not REGISTRATION_CODE:
        raise RuntimeError("BODY_WEIGHT_REGISTRATION_CODE or BODY_WEIGHT_API_TOKEN is required")
    repository = WeightRepository(DATABASE_PATH, PHOTO_DIRECTORY)
    APIHandler.repository = repository
    APIHandler.registration_code = REGISTRATION_CODE
    APIHandler.legacy_api_token = LEGACY_API_TOKEN
    server = ThreadingHTTPServer((HOST, PORT), APIHandler)
    logger.info("Listening on http://%s:%s", HOST, PORT)
    server.serve_forever()


if __name__ == "__main__":
    run()
