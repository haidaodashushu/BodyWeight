import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from server import (
    LEGACY_USER_ID,
    InvalidCredentialsError,
    UsernameTakenError,
    WeightRepository,
)


class WeightRepositoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.database_path = root / "test.sqlite3"
        self.photo_directory = root / "photos"
        self.repository = WeightRepository(self.database_path, self.photo_directory)
        self.user, self.token, _ = self.repository.register("alice", "password-123")
        self.entry_id = str(uuid4())
        self.now = datetime.now(timezone.utc)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def entry(self, *, weight: float, updated_offset: int = 0, deleted: bool = False):
        updated = self.now + timedelta(seconds=updated_offset)
        return {
            "id": self.entry_id,
            "weightKG": weight,
            "recordedAt": self.now.isoformat(),
            "createdAt": self.now.isoformat(),
            "updatedAt": updated.isoformat(),
            "source": "manual",
            "originalText": "",
            "isDeleted": deleted,
        }

    def test_register_login_authenticate_and_logout(self) -> None:
        self.assertEqual(self.repository.authenticate(self.token), self.user)
        logged_in_user, login_token = self.repository.login("ALICE", "password-123")
        self.assertEqual(logged_in_user, self.user)
        self.assertEqual(self.repository.authenticate(login_token), self.user)
        self.repository.logout(login_token)
        self.assertIsNone(self.repository.authenticate(login_token))
        with self.assertRaises(InvalidCredentialsError):
            self.repository.login("alice", "wrong-password")

    def test_duplicate_username_is_case_insensitive(self) -> None:
        with self.assertRaises(UsernameTakenError):
            self.repository.register("Alice", "another-password")

    def test_newest_change_wins_and_deletion_is_preserved(self) -> None:
        created = self.repository.synchronize(self.user["id"], [self.entry(weight=80)])
        self.assertEqual(created[0]["weightKG"], 80)
        older = self.repository.synchronize(
            self.user["id"], [self.entry(weight=90, updated_offset=-1)]
        )
        self.assertEqual(older[0]["weightKG"], 80)
        newer = self.repository.synchronize(
            self.user["id"], [self.entry(weight=79.5, updated_offset=1)]
        )
        self.assertEqual(newer[0]["weightKG"], 79.5)
        deleted = self.repository.synchronize(
            self.user["id"], [self.entry(weight=79.5, updated_offset=2, deleted=True)]
        )
        self.assertTrue(deleted[0]["isDeleted"])

    def test_users_cannot_read_or_overwrite_each_others_entries(self) -> None:
        second_user, _, _ = self.repository.register("bob", "password-456")
        self.repository.synchronize(self.user["id"], [self.entry(weight=80)])
        second_result = self.repository.synchronize(second_user["id"], [self.entry(weight=95)])
        self.assertEqual(second_result[0]["weightKG"], 95)
        first_result = self.repository.synchronize(self.user["id"], [])
        self.assertEqual(first_result[0]["weightKG"], 80)

    def test_rejects_invalid_weight(self) -> None:
        with self.assertRaisesRegex(ValueError, "between 20 and 500"):
            self.repository.synchronize(self.user["id"], [self.entry(weight=5)])

    def test_photo_is_user_scoped_and_removed_with_tombstone(self) -> None:
        second_user, _, _ = self.repository.register("bob", "password-456")
        self.repository.synchronize(self.user["id"], [self.entry(weight=80)])
        self.repository.synchronize(second_user["id"], [self.entry(weight=95)])
        jpeg = b"\xff\xd8daily-photo\xff\xd9"
        photo_time = (self.now + timedelta(seconds=1)).isoformat()
        saved_time = self.repository.save_photo(self.user["id"], self.entry_id, jpeg, photo_time)
        photo = self.repository.get_photo(self.user["id"], self.entry_id)
        self.assertEqual(saved_time, photo_time.replace("+00:00", "Z"))
        self.assertIsNotNone(photo)
        self.assertEqual(photo[0].read_bytes(), jpeg)
        self.assertIsNone(self.repository.get_photo(second_user["id"], self.entry_id))
        synced = self.repository.synchronize(self.user["id"], [])
        self.assertEqual(synced[0]["photoUpdatedAt"], saved_time)
        self.repository.synchronize(
            self.user["id"], [self.entry(weight=80, updated_offset=2, deleted=True)]
        )
        self.assertIsNone(self.repository.get_photo(self.user["id"], self.entry_id))
        self.assertFalse(self.repository.photo_path(self.user["id"], self.entry_id).exists())

    def test_photo_requires_an_existing_entry_for_that_user(self) -> None:
        with self.assertRaises(LookupError):
            self.repository.save_photo(
                self.user["id"], self.entry_id,
                b"\xff\xd8daily-photo\xff\xd9", self.now.isoformat(),
            )


class LegacyMigrationTests(unittest.TestCase):
    def test_first_registered_user_claims_legacy_entries_and_photos(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database_path = root / "legacy.sqlite3"
            photo_directory = root / "photos"
            photo_directory.mkdir()
            entry_id = str(uuid4())
            now = datetime.now(timezone.utc).isoformat()
            with sqlite3.connect(database_path) as connection:
                connection.execute(
                    """
                    CREATE TABLE weight_entries (
                        id TEXT PRIMARY KEY, weight_kg REAL NOT NULL,
                        recorded_at TEXT NOT NULL, created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL, source TEXT NOT NULL,
                        original_text TEXT NOT NULL DEFAULT '',
                        is_deleted INTEGER NOT NULL DEFAULT 0,
                        photo_updated_at TEXT
                    )
                    """
                )
                connection.execute(
                    "INSERT INTO weight_entries VALUES (?, 80, ?, ?, ?, 'manual', '', 0, ?)",
                    (entry_id, now, now, now, now),
                )
            (photo_directory / f"{entry_id}.jpg").write_bytes(b"\xff\xd8legacy\xff\xd9")

            repository = WeightRepository(database_path, photo_directory)
            with sqlite3.connect(database_path) as connection:
                migrated_user_id = connection.execute(
                    "SELECT user_id FROM weight_entries"
                ).fetchone()[0]
            self.assertEqual(migrated_user_id, LEGACY_USER_ID)

            user, _, claimed = repository.register("owner", "password-123")
            self.assertTrue(claimed)
            entries = repository.synchronize(user["id"], [])
            self.assertEqual(entries[0]["id"], entry_id)
            self.assertIsNotNone(repository.get_photo(user["id"], entry_id))
            self.assertFalse((photo_directory / f"{entry_id}.jpg").exists())


if __name__ == "__main__":
    unittest.main()
