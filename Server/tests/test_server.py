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


if __name__ == "__main__":
    unittest.main()
