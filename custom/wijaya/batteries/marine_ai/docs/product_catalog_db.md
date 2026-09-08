# Marine Product Catalog — Read-Only Catalog Database

Commit 1B reads the canonical Marine item data through a **separate, read-only**
PostgreSQL connection (`Marine::Catalog::Config` / `Connection` /
`ProductFamilyRepository`). This connection is entirely independent of the Chatwoot
application database and is used only for parameterized, `SELECT`-only product-family
lookups.

> The dev runtime for these variables will be configured by Hermes later. This document
> only specifies the contract. **Do not commit credentials.**

## Runtime configuration (`MARINE_CATALOG_PG_*`)

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `MARINE_CATALOG_PG_HOST` | yes | — | Catalog cluster host. |
| `MARINE_CATALOG_PG_PORT` | no | `5432` | Catalog cluster port. |
| `MARINE_CATALOG_PG_DATABASE` | yes | — | Catalog database name. |
| `MARINE_CATALOG_PG_USER` | yes | — | Dedicated **read-only** login role (see below). |
| `MARINE_CATALOG_PG_PASSWORD_FILE` | yes | — | Path to a read-only secret file holding the role password. |
| `MARINE_CATALOG_PG_SCHEMA` | no | `marine_ai` | Schema holding the item table. |
| `MARINE_CATALOG_PG_TABLE` | no | `item` | Canonical item table (singular). |
| `MARINE_CATALOG_PG_SSLMODE` | no | `prefer` | libpq `sslmode`. |

`configured?` is true only when host, database, user, and a readable password file are
all present; otherwise the repository fails closed with `CatalogUnavailableError` (503).

## Schema / table defaults

- Schema: `marine_ai`, table: `item` (**singular** — matches the live schema).
- A **product family** is the template row where `has_variants = true`. Existence is
  never inferred from a child/variant row (`variant_of`). `exists?` matches exactly on
  `item_code = $1 AND has_variants = true`; `search` lists template rows
  (`has_variants = true`) ordered by `item_code`.
- Schema/table are operator-configured (never client input) and are validated against a
  strict identifier pattern before interpolation, as defense-in-depth. All client-supplied
  values (family code, query) are always passed as bind parameters, never interpolated.

## Dedicated read-only DB role (required)

Create a **dedicated login role** for `MARINE_CATALOG_PG_USER` with the least privilege
needed to read the item table only, e.g.:

```sql
CREATE ROLE marine_catalog_ro LOGIN PASSWORD '<from secret file>';
GRANT CONNECT ON DATABASE <catalog_db> TO marine_catalog_ro;
GRANT USAGE ON SCHEMA marine_ai TO marine_catalog_ro;
GRANT SELECT ON marine_ai.item TO marine_catalog_ro;
```

Every catalog connection additionally forces `SET default_transaction_read_only = on`
and applies short connect / statement / lock timeouts, so a stuck cluster can never hang
a request thread. Raw PG errors, SQL text, and the password never propagate to the API or
the logs.

- **Do NOT** reuse the Marine provisioning admin/superuser login for catalog reads. That
  credential exists only for one-off provisioning and must never be used at request time.
- **Do NOT** grant this role write privileges or access beyond the item table.

## Password-file handling

The password is read on demand from `MARINE_CATALOG_PG_PASSWORD_FILE` (a read-only secret
file) for the in-memory `PG.connect` call only. It is never persisted, logged, echoed, or
returned through the API. Deliver it the same way as the provisioning secret — a read-only
file mounted into the Rails container — and keep the file out of version control.
