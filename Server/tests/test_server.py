import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

from server import WeightRepository


class WeightRepositoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = WeightRepository(Path(self.temporary_directory.name) / "test.sqlite3")
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

    def test_newest_change_wins_and_deletion_is_preserved(self) -> None:
        created = self.repository.synchronize([self.entry(weight=80)])
        self.assertEqual(created[0]["weightKG"], 80)

        older = self.repository.synchronize([self.entry(weight=90, updated_offset=-1)])
        self.assertEqual(older[0]["weightKG"], 80)

        newer = self.repository.synchronize([self.entry(weight=79.5, updated_offset=1)])
        self.assertEqual(newer[0]["weightKG"], 79.5)

        deleted = self.repository.synchronize([self.entry(weight=79.5, updated_offset=2, deleted=True)])
        self.assertTrue(deleted[0]["isDeleted"])

    def test_rejects_invalid_weight(self) -> None:
        with self.assertRaisesRegex(ValueError, "between 20 and 500"):
            self.repository.synchronize([self.entry(weight=5)])

    def test_photo_is_bound_to_entry_and_removed_with_tombstone(self) -> None:
        self.repository.synchronize([self.entry(weight=80)])
        jpeg = b"\xff\xd8daily-photo\xff\xd9"
        photo_time = (self.now + timedelta(seconds=1)).isoformat()

        saved_time = self.repository.save_photo(self.entry_id, jpeg, photo_time)
        photo = self.repository.get_photo(self.entry_id)

        self.assertEqual(saved_time, photo_time.replace("+00:00", "Z"))
        self.assertIsNotNone(photo)
        self.assertEqual(photo[0].read_bytes(), jpeg)
        synced = self.repository.synchronize([])
        self.assertEqual(synced[0]["photoUpdatedAt"], saved_time)

        self.repository.synchronize([self.entry(weight=80, updated_offset=2, deleted=True)])
        self.assertIsNone(self.repository.get_photo(self.entry_id))
        self.assertFalse(self.repository.photo_path(self.entry_id).exists())

    def test_photo_requires_an_existing_entry(self) -> None:
        with self.assertRaises(LookupError):
            self.repository.save_photo(
                self.entry_id,
                b"\xff\xd8daily-photo\xff\xd9",
                self.now.isoformat(),
            )


if __name__ == "__main__":
    unittest.main()
