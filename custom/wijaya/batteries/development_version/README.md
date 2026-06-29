# Wijaya Development Version Battery

Independent semantic versioning for Wijaya Corp's custom development, decoupled
from official Chatwoot versioning. The internal dev version starts at `v0.1.0`
and is shown on **General Settings** alongside the official Chatwoot version and
build SHA (it does not replace them).

## Files

- `version.yml` — single source of truth for the current internal dev version.
- `CHANGELOG.md` — human-readable history of internal dev versions.
- `hooks.rb` — `Wijaya::Batteries::DevelopmentVersion::Hooks`, exposing
  `current_version` (used by the dashboard) plus pure bump helpers.
- `scripts/bump_version.rb` — CLI to bump the version and update the changelog.

## Versioning rules (MAJOR.MINOR.PATCH)

This version tracks **Wijaya custom development only**, not upstream Chatwoot.

- **MAJOR** — incompatible/breaking changes to Wijaya customizations or removal
  of a battery/behavior other customizations depend on.
- **MINOR** — new Wijaya feature or battery added in a backward-compatible way.
- **PATCH** — backward-compatible bug fixes or small tweaks to existing Wijaya
  customizations.

The official Chatwoot version (`appVersion`) and build SHA are unchanged and
continue to follow upstream semantics.

## Bump workflow

Run from the battery directory (local Ruby or inside the Rails container):

```bash
cd custom/wijaya/batteries/development_version

# Inspect current version
ruby scripts/bump_version.rb --current

# Preview a bump without writing files
ruby scripts/bump_version.rb minor "Add foo battery" --dry-run

# Apply a bump (updates version.yml + prepends CHANGELOG.md)
ruby scripts/bump_version.rb patch "Fix bar edge case"
ruby scripts/bump_version.rb minor "Add baz feature"
ruby scripts/bump_version.rb major "Breaking change to qux battery"
```

Inside the container, prefix with the app path, e.g.:

```bash
docker exec chatwoot-rails-1 \
  ruby /app/custom/wijaya/batteries/development_version/scripts/bump_version.rb --current
```

The script validates the semantic-version format, prints the old and new
version, updates `version.yml`, and prepends a dated section to `CHANGELOG.md`.
Commit both files together after bumping.

## How it surfaces in the UI

1. `app/controllers/dashboard_controller.rb#app_config` adds `WIJAYA_DEV_VERSION`
   by calling `Wijaya::Batteries::DevelopmentVersion::Hooks.current_version`
   (bracketed by `WIJAYA_CUSTOM_START/END development_version`).
2. `app/javascript/shared/store/globalConfig.js` maps `WIJAYA_DEV_VERSION` to
   `wijayaDevVersion`.
3. `app/javascript/dashboard/routes/dashboard/settings/account/components/BuildInfo.vue`
   renders the Wijaya Dev version next to the official version and build SHA.
