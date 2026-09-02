# Body Weight API

Multi-user synchronization service implemented with the Python standard library and SQLite.

## Endpoints

- `GET /health` — public liveness check
- `POST /v1/auth/register` — create an account using the server registration code
- `POST /v1/auth/login` — log in and receive a session token
- `POST /v1/auth/logout` — revoke the current session token
- `GET /v1/auth/me` — return the current account
- `POST /v1/sync` — account-scoped, last-write-wins synchronization
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

Passwords are stored as salted PBKDF2-SHA256 hashes. Login creates a random, revocable session token;
only its SHA-256 digest is stored. Set `BODY_WEIGHT_REGISTRATION_CODE` to control who may create an
account. For upgrades, the old `BODY_WEIGHT_API_TOKEN` is used as the registration code when the new
setting is absent. The first registered account automatically claims the legacy records and photos.

Photo uploads use `Content-Type: image/jpeg` and an ISO-8601 `X-Photo-Updated-At` header. Images are
limited to 12 MB and stored below a directory for the authenticated user. Deleted entries are retained
as tombstones so deletions synchronize safely between devices; their associated image files are removed.

The production deployment creates a transactionally consistent SQLite backup every day and retains
the latest 30 snapshots in `/var/backups/body-weight-api`. The current photo set is mirrored to
`/var/backups/body-weight-api/photos`.

## Tests

```bash
cd Server
python3 -m unittest discover -s tests -v
```
