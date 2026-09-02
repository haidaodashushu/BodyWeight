# Body Weight API

Single-user synchronization service implemented with the Python standard library and SQLite.

## Endpoints

- `GET /health` — public liveness check
- `POST /v1/sync` — bearer-token-protected, last-write-wins synchronization

The sync endpoint accepts and returns:

```json
{
  "entries": [{
    "id": "UUID",
    "weightKG": 80.5,
    "recordedAt": "2026-09-02T00:00:00Z",
    "createdAt": "2026-09-02T00:00:00Z",
    "updatedAt": "2026-09-02T00:00:00Z",
    "source": "manual",
    "originalText": "",
    "isDeleted": false
  }]
}
```

Deleted entries are retained as tombstones so deletions synchronize safely between devices.

The production deployment creates a transactionally consistent SQLite backup every day and retains
the latest 30 snapshots in `/var/backups/body-weight-api`.

## Tests

```bash
cd Server
python3 -m unittest discover -s tests -v
```
