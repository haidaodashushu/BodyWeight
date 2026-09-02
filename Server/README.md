# Body Weight API

Single-user synchronization service implemented with the Python standard library and SQLite.

## Endpoints

- `GET /health` — public liveness check
- `POST /v1/sync` — bearer-token-protected, last-write-wins synchronization
- `PUT /v1/photos/<entry UUID>` — upload the JPEG attached to a weight entry
- `GET /v1/photos/<entry UUID>` — download the JPEG attached to a weight entry

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
    "isDeleted": false,
    "photoUpdatedAt": "2026-09-02T00:01:00Z"
  }]
}
```

Photo uploads use `Content-Type: image/jpeg` and an ISO-8601 `X-Photo-Updated-At` header. Images are
limited to 12 MB. Deleted entries are retained as tombstones so deletions synchronize safely between
devices; their associated image files are removed.

The production deployment creates a transactionally consistent SQLite backup every day and retains
the latest 30 snapshots in `/var/backups/body-weight-api`. The current photo set is mirrored to
`/var/backups/body-weight-api/photos`.

## Tests

```bash
cd Server
python3 -m unittest discover -s tests -v
```
