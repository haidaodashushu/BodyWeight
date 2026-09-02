#!/usr/bin/env python3
"""Create a consistent SQLite backup and retain the latest 30 daily snapshots."""

from __future__ import annotations

import os
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


database_path = Path(os.environ.get("BODY_WEIGHT_DATABASE_PATH", "/var/lib/body-weight-api/body-weight.sqlite3"))
photo_directory = Path(os.environ.get("BODY_WEIGHT_PHOTO_PATH", "/var/lib/body-weight-api/photos"))
backup_directory = Path(os.environ.get("BODY_WEIGHT_BACKUP_PATH", "/var/backups/body-weight-api"))
retention_count = int(os.environ.get("BODY_WEIGHT_BACKUP_RETENTION", "30"))

if not database_path.exists():
    raise SystemExit(f"Database does not exist: {database_path}")

backup_directory.mkdir(parents=True, exist_ok=True)
timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
destination_path = backup_directory / f"body-weight-{timestamp}.sqlite3"
temporary_path = destination_path.with_suffix(".sqlite3.tmp")

try:
    with sqlite3.connect(database_path) as source, sqlite3.connect(temporary_path) as destination:
        source.backup(destination)
    temporary_path.replace(destination_path)
finally:
    temporary_path.unlink(missing_ok=True)

backups = sorted(backup_directory.glob("body-weight-*.sqlite3"), reverse=True)
for expired_backup in backups[retention_count:]:
    expired_backup.unlink()

photo_backup_directory = backup_directory / "photos"
photo_backup_directory.mkdir(parents=True, exist_ok=True)
source_relative_paths: set[Path] = set()
if photo_directory.exists():
    for source_photo in photo_directory.rglob("*.jpg"):
        relative_path = source_photo.relative_to(photo_directory)
        source_relative_paths.add(relative_path)
        destination_photo = photo_backup_directory / relative_path
        destination_photo.parent.mkdir(parents=True, exist_ok=True)
        if not destination_photo.exists() or source_photo.stat().st_mtime_ns > destination_photo.stat().st_mtime_ns:
            shutil.copy2(source_photo, destination_photo)
for stale_photo in photo_backup_directory.rglob("*.jpg"):
    if stale_photo.relative_to(photo_backup_directory) not in source_relative_paths:
        stale_photo.unlink()

print(destination_path)
