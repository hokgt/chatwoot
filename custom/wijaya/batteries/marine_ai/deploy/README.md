# Marine PostgreSQL Provisioning — Deployment & Secret Handling

This battery adds an **installation-level** admin UI (Marine AI → Settings →
*Database & Account Setup*) that provisions a dedicated Marine database and a
single login account inside the **existing** PostgreSQL cluster, and manages that
login's privileges. All SQL orchestration lives in the battery services under
`custom/wijaya/batteries/marine_ai/app/services/marine/provisioning/`. Controllers
only delegate; Vue components never contain SQL.

Because the state and actions are installation-wide, every endpoint is restricted
to a Chatwoot **installation SuperAdmin** who is also an account administrator — a
regular account administrator (or agent) is denied by `Marine::ProvisioningPolicy`.
The frontend mirrors this and only renders/fetches the section for a SuperAdmin
administrator; the backend policy is the real gate.

## Why a superuser secret

Creating a database and roles requires cluster-level privileges the normal
Chatwoot application role should not carry into request handling. The provisioner
therefore connects with the **existing PostgreSQL superuser** credential — the same
role your deployment already uses (`POSTGRES_USERNAME`) — supplied **only** via a
read-only Docker secret file. No separate `marine_bootstrap` account is required;
only the superuser's password is delivered through the secret file. This password
is:

- **Never** stored in the Chatwoot DB, `InstallationConfig`, Redis, logs, the
  frontend, the API, or exception messages.
- **Never** written back into the app DB or echoed to any client.
- Read on demand from the file at `MARINE_PROVISIONING_PG_PASSWORD_FILE` and used
  only for the in-memory `PG.connect` call.

If the file is missing/empty/unreadable, provisioning **fails closed** with a
sanitized *"provisioning credential unavailable"* error.

## Configuration

Non-secret settings come from env vars (see `marine-provisioning.env.example`):

| Variable | Purpose |
|---|---|
| `MARINE_PROVISIONING_PG_HOST` | Cluster host |
| `MARINE_PROVISIONING_PG_PORT` | Cluster port |
| `MARINE_PROVISIONING_PG_ADMIN_USER` | Existing superuser **username** (defaults to `POSTGRES_USERNAME`) |
| `MARINE_PROVISIONING_PG_MAINTENANCE_DB` | Maintenance DB for DDL (default `postgres`) |
| `MARINE_PROVISIONING_PG_SSLMODE` | SSL mode (default `prefer`; set to `disable` for single-host clusters without TLS) |
| `MARINE_PROVISIONING_PG_PASSWORD_FILE` | In-container path to the secret file |

The password itself is delivered by the Docker secret defined in the overlay. The
secret is mounted **only** into the `rails` service — the provisioning UI runs in
the web process, so `sidekiq` never receives it.

> **SSL note:** the "Show current privileges" matrix reports the connection's
> *effective* SSL usage as read from `pg_stat_ssl` for the provisioning session,
> falling back to the configured `sslmode` when unavailable. Verify this matches
> your cluster's expectation before relying on it.

## Deploy (compose overlay — core files untouched)

Core `docker-compose.production.yaml` is **not** modified. Apply the battery
overlay on top:

```bash
# 1. Place the EXISTING superuser password in a host file that is NOT committed:
install -m 0400 /dev/stdin /srv/secrets/marine_provisioning_pg_password <<'EOF'
<the-existing-postgres-superuser-password>
EOF

# 2. Export the non-secret settings (or use an env file):
export MARINE_PROVISIONING_PG_ADMIN_USER=postgres
export MARINE_PROVISIONING_PG_PASSWORD_FILE_HOST=/srv/secrets/marine_provisioning_pg_password

# 3. Bring the app up WITH the overlay (rails only needs the secret):
docker compose \
  -f docker-compose.production.yaml \
  -f custom/wijaya/batteries/marine_ai/deploy/docker-compose.marine-provisioning.yml \
  up -d rails
```

> **Never commit** the secret file. Add its host path to your deployment's secret
> management. The example path above is illustrative only.

## What "Create" does (once, on explicit click)

1. Validates the admin-supplied database name and login username (strict
   PostgreSQL-safe rules; reserved and current-Chatwoot names rejected) and the
   login password (length + control-character safety).
2. Under an advisory lock, in a compensating saga:
   - creates an internal **NOLOGIN owner** role with least-privilege attributes
     (admin never handles it);
   - creates exactly one login account **NOLOGIN** initially, with the submitted
     password already set and the same least-privilege attributes;
   - `CREATE DATABASE` owned by the internal owner;
   - inside the new DB: revokes `PUBLIC` `CONNECT`/`TEMPORARY`, revokes `ALL` on
     the default `public` schema, and grants the login `CONNECT` + `CREATE` on the
     database. It does **not** create the `marine_ai` schema (see below);
   - hardens the existing Chatwoot DB **inside a transaction**, recording the
     prior `PUBLIC` `CONNECT` and any prior explicit app-role `CONNECT` ACL first:
     `REVOKE CONNECT ... FROM PUBLIC` and an explicit `GRANT CONNECT` to the current
     app role, committed atomically;
   - verifies a **fresh** connection for the current Chatwoot app role still
     succeeds *after* the hardening commit;
   - only then, as the **final** PostgreSQL step, `ALTER ROLE ... LOGIN` activates
     the login — so the new credential can never reach the Chatwoot DB through
     `PUBLIC` during the isolation window — before marking setup complete.
3. If any step fails, the saga compensates (drops what it created, restores the
   Chatwoot ACL to its exact prior posture: re-grants `PUBLIC` `CONNECT` only if it
   existed before, and revokes the explicit app-role `CONNECT` only if that grant
   did not exist before). If compensation also fails, a sanitized
   `needs_manual_cleanup` state is persisted (never with secrets).

> **The UI does NOT create the `marine_ai` schema.** The provisioner login is granted
> `CREATE` on the new database precisely so the **ERP** can create and own the
> `marine_ai` schema and its objects. A later **Downgrade** REASSIGNs that ownership
> to the internal NOLOGIN owner and then grants the login writer-only DML. Downgrade
> fails safely if the ERP has not yet created the `marine_ai` schema.

Durable, **non-secret** state is stored in a single `MARINE_PROVISIONING_STATE`
`InstallationConfig` row. Neither the login password nor the superuser password is
ever persisted. The one-time credential popup shows only non-secret connection
metadata plus the password the admin just typed (held in browser memory only).

### Scope of the CONNECT hardening

The `PUBLIC CONNECT` hardening applies to **exactly one** database: the existing
Chatwoot application database (the one this Rails app is connected to). It revokes
`PUBLIC` `CONNECT` on **that** database and re-grants an explicit
`CONNECT` to the current app role, so the new Marine login cannot reach the Chatwoot
DB through `PUBLIC` while its own database is being set up. This is **not** a
cluster-wide lockdown: ACLs on other, unrelated databases in the shared PostgreSQL
cluster are **never** read or modified, and no claim of denial to every other cluster
database is made or implied. The connectivity check likewise reproduces the current
Chatwoot ActiveRecord endpoint only.

## Privilege management

All privilege actions acquire the shared advisory lock **first**, re-read the durable
privilege level under the lock, validate the transition there, run the DDL, and persist
the new level while still holding the lock — so a stale concurrent action cannot run
after another already changed the level. If the DDL COMMITs but the state write fails,
the tool raises a state-sync error for **manual reconciliation** (it does **not** claim
a rollback — the two databases cannot share one transaction).

- **Downgrade to Writer** — atomically (single DB transaction) reassigns objects
  owned by the login to the internal owner, `DROP OWNED BY` the login to remove all
  its grants across every schema, explicitly `REVOKE`s every role membership granted
  to the login (`DROP OWNED` does not do this), strips `PUBLIC` `EXECUTE` on
  `marine_ai` functions/procedures, then grants only `CONNECT`, `USAGE` on
  `marine_ai`, and `SELECT/INSERT/UPDATE/DELETE` on current `marine_ai` tables (no
  `TRUNCATE`, no `CREATE`, no function/sequence privileges), verifies the login owns
  zero objects cluster-wide, and only then persists `writer` state. Allowed only from
  `admin` state. The internal owner is re-verified NOLOGIN **and** free of elevated
  attributes before any reassignment.
- **Show current privileges** — read-only matrix from the catalogs, including role
  attributes (login, superuser, createrole, createdb, replication, bypassrls), role
  memberships (must be empty), whether the login can `CONNECT` to the existing
  Chatwoot DB (must be **false**, reported as *unknown* if the check itself errors),
  per-table DML coverage across **all** vs **any** `marine_ai` tables with a total
  table count, and effective function/sequence privilege flags (must be **false** for
  an exact writer).
- **Revoke all** — atomically reassigns owned objects, `DROP OWNED BY` the login,
  revokes every role membership, and `ALTER ROLE NOLOGIN`. Idempotent from any active
  state. Never drops the database, schema, tables, or data.
