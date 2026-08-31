# Wijaya Battery Hooks

This document inventories every point where native Chatwoot runtime code delegates
to a Wijaya feature battery. Each native touch point is a thin, marker-wrapped
(`# WIJAYA_CUSTOM_START <feature>` / `# WIJAYA_CUSTOM_END <feature>`) call that carries
zero business logic — all logic lives under `custom/wijaya/batteries/<feature>/`.

## Core mechanism

- **Backend dispatcher** — `Wijaya::Batteries::Core::Hooks.dispatch(feature, hook, default:, **kwargs)`
  resolves the feature's `Hooks` module (via `FEATURE_HOOK_MODULES`), calls `hook`, and
  returns `default` if the battery is missing, disabled, unconfigured, or raises. This is
  the single fail-open seam: any `StandardError` **or `ScriptError`** (e.g. `LoadError`/
  `SyntaxError` from a broken battery file) is rescued and the native `default` is returned,
  so a broken/absent battery can never change native behavior. The log line records only the
  feature, hook, and `error.class` — never `error.message` — so no battery internals or
  remote payloads can leak through the boot/runtime log.
- **Undefined-constant guard** — every native touch point wraps its `dispatch` call in
  `if defined?(Wijaya::Batteries::Core::Hooks)` (or `return <default> unless defined?(...)`).
  In a booted app the generic initializer (`config/initializers/wijaya.rb`) loads the core
  hooks module, so the seam dispatches normally. But if the battery system never booted (the
  constant is undefined), the native touch point uses/returns its **exact upstream default**
  and never raises `NameError` — no per-feature `require` of the core file is needed at the
  seam. The `spec/custom/wijaya/batteries/core/native_seam_fail_open_spec.rb` regression proves
  this branch by hiding the constant per-example (RSpec `hide_const`, auto-restored).
- **Loader** — `Wijaya::Batteries::Core::Loader` discovers each `custom/wijaya/batteries/*/loader.rb`,
  requires it (self-registration), and runs each `setup!` inside its own rescue (both
  `StandardError` and `ScriptError`). One broken battery cannot stop boot or the others
  (fail open at boot; the feature stays unavailable — fail closed for the feature). Logs
  record only the battery name and `error.class`. The `config/initializers/wijaya.rb`
  bootstrap wraps the `require`/`setup!` in the same rescue, so even a load failure of the
  core files leaves native boot intact.
- **Route registrar** — `Wijaya::Batteries::Routes.draw(mapper)` iterates `ROUTE_MODULES`
  (feature → module name) and, per battery, `require`s that battery's own
  `custom/wijaya/batteries/<feature>/routes.rb` and calls `<Module>.draw(mapper)` inside an
  isolated rescue (`StandardError`/`ScriptError`). The route DSL for each battery lives in the
  battery; core only orchestrates. One battery's route error cannot suppress the others or the
  native route set, and the log records only the battery name and `error.class`.
- **Frontend contributions** — native Vue files import a compact builder from a battery
  (`@wijaya/<feature>/frontend/...`) and call it once. Arrays/labels/predicates/API selection
  stay in the battery; the native file carries only the delegation.

---

## Backend hooks

### 1. `meta_ads_team_routing` → `apply_team_routing!`

- **Call sites**
  - `app/builders/messages/facebook/message_builder.rb` (channel `:messenger`)
  - `app/builders/messages/instagram/base_message_builder.rb` (channel `:instagram`)
  - `app/services/whatsapp/incoming_message_base_service.rb` (channel `:whatsapp`)
- **Purpose** — before a brand-new conversation is created for an inbound Meta message,
  route it to a configured team based on the ad's source ID (referral).
- **Flow** — exactly one `dispatch(:meta_ads_team_routing, :apply_team_routing!,
  default: new_conversation_params, account:, inbox:, channel:, referral:,
  conversation_params: new_conversation_params)` immediately before `Conversation.create!`, and
  the native builder **assigns the return value** back to its params variable. The battery
  operates on an isolated duplicate (`conversation_params.dup`) and **returns** the resulting
  params; it never mutates the caller's hash.
- **Native default** — the caller's own `new_conversation_params`. If the battery is missing,
  disabled, or raises, the dispatcher returns this default, so the builder proceeds with exactly
  the params it produced.
- **Fail mode** — **fail open**. Dispatcher rescues and returns the native default; because the
  battery never mutates the passed hash, a mid-routing failure cannot leave the params partially
  modified. No referral data leaks into the conversation on error.
- **Risk** — low. Only mutates params before create; never blocks conversation creation.
- **Necessity** — required: this is the only insertion point before `Conversation.create!` on
  each Meta channel.

### 2. `marine_ai` → `claim_message_templates!`

- **Call site** — `app/services/message_templates/hook_execution_service.rb`
- **Purpose** — let the Marine assistant claim an inbound conversation and suppress the native
  greeting / out-of-office / email-collect templates when Marine is handling the inbox.
- **Flow** — `return if dispatch(:marine_ai, :claim_message_templates!, default: false, conversation:,
  inbox:, message:)`. A truthy return short-circuits the native template execution.
- **Native default** — `false` → native greeting/OOO/email-collect templates run exactly as before.
- **Fail mode** — **fail open**. On missing/disabled/raising battery the default `false` preserves
  all native template behavior.
- **Risk** — low. Worst case on battery error is that native templates run (native behavior).
- **Necessity** — required to gate native templates without editing the native service body.

### 3. `marine_ai` → `inbox_marine_assistant_id`

- **Call site** — `app/views/api/v1/models/_inbox.json.jbuilder`
- **Purpose** — expose the linked Marine assistant id on the inbox JSON payload.
- **Flow** — `json.marine_assistant_id dispatch(:marine_ai, :inbox_marine_assistant_id, default: nil,
  inbox: resource)`.
- **Native default** — `nil` → the field renders `null`; the rest of the inbox JSON is untouched.
- **Fail mode** — **fail open**. Renders native inbox JSON with `marine_assistant_id: null` on error.
- **Risk** — very low. Additive read-only field.
- **Necessity** — required to surface the assistant link without forking the jbuilder.

### 4. `development_version` → `enrich_app_config`

- **Call site** — `app/controllers/dashboard_controller.rb`
- **Purpose** — add the deployed build/version metadata to the dashboard app config.
- **Flow** — `dispatch(:development_version, :enrich_app_config, default: config, config: config)`.
- **Native default** — the unmodified `config` hash.
- **Fail mode** — **fail open**. Returns the native `config` unchanged on error.
- **Risk** — very low. Additive metadata only.
- **Necessity** — required to inject build info without editing the controller body.

### 5. Route registration — `Wijaya::Batteries::Routes.draw(self)`

- **Call site** — `config/routes.rb` (single marker-wrapped `draw` call inside the api/v1
  `scope module: :accounts` block).
- **Purpose** — register all Marine and Wijaya (`meta_ads_team_routing`, `erp_lead_sidebar`)
  endpoints.
- **Flow** — `draw` iterates `ROUTE_MODULES` (`marine_ai` → `Wijaya::Marine::Routes`,
  `meta_ads_team_routing` → `Wijaya::Batteries::MetaAdsTeamRouting::Routes`, `erp_lead_sidebar` →
  `Wijaya::Batteries::ErpLeadSidebar::Routes`) and, per battery, `require`s that battery's own
  `custom/wijaya/batteries/<feature>/routes.rb` and calls `<Module>.draw(mapper)` inside its own
  rescue. **The actual route DSL for each battery lives in that battery's `routes.rb`; core owns
  no endpoint definitions** — only the generic per-battery orchestration and fail-open isolation.
- **Fail mode** — **fail open, per battery**. A require/draw error in one battery is logged (battery
  name + `error.class` only) and swallowed without affecting the other batteries or the native route
  set.
- **Risk** — low. Isolated per battery.
- **Necessity** — required; native `config/routes.rb` keeps only the single generic call.

---

## Frontend hooks

### 6. `marine_ai` — sidebar section builder

- **Call site** — `app/javascript/dashboard/components-next/sidebar/Sidebar.vue`
- **Purpose** — contribute the whole Marine primary sidebar section.
- **Flow** — `buildMarineSidebarSection({ t, accountScopedRoute })` from
  `@wijaya/marine_ai/frontend/sidebar/marineSidebarSection`; called once. All menu
  structure/labels/routes live in the battery; labels read from the `MARINE_AI` i18n namespace.
- **Necessity** — required to keep the section out of the native file.

### 7. `meta_ads_team_routing` — settings sidebar item builder

- **Call site** — `app/javascript/dashboard/components-next/sidebar/Sidebar.vue`
- **Purpose** — contribute the single "Meta Ads Routing" settings entry.
- **Flow** — `buildMetaAdsRoutingSidebarItem({ t, accountScopedRoute })` from
  `@wijaya/meta_ads_team_routing/frontend/sidebar/metaAdsRoutingSidebarItem`; called once. The
  label reads from the battery's own i18n namespace (`META_ADS_ROUTING.SIDEBAR_LABEL`) — no core
  settings key is used.
- **Necessity** — required to keep the entry and its string battery-owned.

### 8. `marine_ai` — Captain composable extension

- **Call site** — `app/javascript/dashboard/composables/useCaptain.js`
- **Purpose** — route Marine conversations to Marine task/translate APIs while leaving native
  Captain behavior byte-for-byte for non-Marine conversations.
- **Flow** — the native composable is restored to its upstream baseline (uses `TasksAPI.*`
  directly for every method). The only marker-wrapped changes are (a) an import of
  `withMarineCaptain` from `@wijaya/marine_ai/frontend/useMarineCaptain` and (b) wrapping the
  returned API object in `withMarineCaptain(...)`. The adapter is the single Battery-owned seam:
  it derives its own conversation/inbox/`isMarineConversation` state, owns `MarineTasksAPI`,
  `translateContent`, and event routing, returns the native API **unchanged** for non-Marine
  conversations, and overrides only the task/translate methods (per-call `isMarineConversation`
  check) for Marine conversations. Non-Marine `translate`/`translate_reply` still go through the
  native `rewriteContent` path exactly.
- **Fail mode** — **fail closed for Marine, native otherwise**. If the adapter's Marine calls
  error, they fall back to `{ message: '', errorType }`; non-Marine paths delegate straight to
  native and are unaffected.
- **Risk** — medium (touches a shared composable); covered by the native `useCaptain.spec.js`
  (non-Marine Captain regression) and the Battery's `frontend/specs/useMarineCaptain.spec.js`
  (delegation, Marine routing, `captainTasksEnabled`, error fallback, translate passthrough).
- **Necessity** — required; there is no non-invasive extension point on this composable, so the
  import + single return-boundary wrapper is the minimal accepted hook.

### 9. `persistent_agent_presence` — presence heartbeat driver

- **Call site** — `app/javascript/shared/helpers/BaseActionCableConnector.js`
- **Purpose** — keep an authenticated agent ONLINE while their tab/window stays open, even when
  unfocused or backgrounded, so online-only auto-assignment keeps reaching them.
- **Flow** — the native connector no longer arms its own main-thread `setTimeout` ping. Two thin
  marker blocks (a) import `createPersistentPresenceHeartbeat` from
  `@wijaya/persistent_agent_presence/frontend/createPresenceHeartbeat` and (b) call it in the
  constructor with `() => this.subscription.updatePresence()` and the existing `presenceInterval`,
  storing the returned `stopPresenceHeartbeat`. A third block calls that stop function in
  `disconnect()`. The battery owns a dedicated Web Worker whose timer avoids the ordinary
  main-thread hidden-tab throttling that delayed the upstream ping past the backend 20s presence
  window. Because the backend TTL check is strict (`connected_time > now - window`) on integer
  seconds, the worker heartbeats at **half** the supplied window (~10s for the default 20s window,
  floored at 1ms) so a slightly late ping still lands inside the window. It falls back to the
  upstream recursive `setTimeout` at the full upstream cadence when Web Workers are unavailable.
- **Fail mode** — **fail safe to upstream**. Worker unavailable/blocked → main-thread setTimeout
  fallback (upstream behavior). A worker is not exempt from every browser/OS suspension: a fully
  frozen, discarded, or killed page/process cannot run its timer, so page close / logout / crash /
  network loss / frozen tab all stop the pings and the native Redis presence window (TTL) expires
  the agent. Presence is never faked for a client that is gone; no backend or assignment semantics
  change.
- **Risk** — low (shared connector; additive, page-scoped). Covered by the Battery's
  `frontend/specs/createPresenceHeartbeat.spec.js` (worker cadence, hidden-tab resilience,
  fallback, idempotent stop) and `frontend/specs/BaseActionCableConnector.integration.spec.js`
  (worker-backed ping, hidden-tab delivery, disconnect cleanup).
- **Necessity** — required; there is no non-invasive extension point on the connector's heartbeat,
  so the import + constructor call + disconnect cleanup is the minimal accepted hook.

### 10. Other frontend battery contributions

The following native files carry marker-wrapped delegations to their batteries (i18n merges,
route table entries, store module registration, permission predicates, message rendering). Each is
additive and isolated to its battery namespace:

- `i18n/locale/en/index.js` — spreads `marine_ai` and `meta_ads_team_routing` i18n namespaces.
- `routes/dashboard/dashboard.routes.js`, `settings/settings.routes.js` — battery route tables.
- `store/index.js` — registers the `meta_ads_team_routing` store module.
- `components-next/message/Message.vue` — `ads_tracking_ctwa_referral` render block.
- `components/widgets/WootWriter/CopilotMenuBar.vue` — the native "Ask Copilot" item is pushed
  unconditionally; the return is wrapped once in `filterMarineCopilotMenu(items, { isMarineConversation })`
  from `@wijaya/marine_ai/frontend/copilotMenu`, which drops the `ask_copilot` item only for Marine
  conversations. `ReplyTopPanel.vue` passes the single adapter-owned `isMarineConversation` boolean.
- `routes/dashboard/conversation/ContactPanel.vue` — ERP lead sidebar panel mount.
- `helper/permissionsHelper.js`, `customRoles/*`, `conversation/*`, `conversationBulkActions/*`,
  `contextMenu/*`, `store/modules/customRole.js` — `custom_roles_rbac` predicates/routes (Phase A/B).
- `settings/account/components/BuildInfo.vue` — imports and mounts
  `@wijaya/development_version/frontend/BuildVersion.vue`, which reads
  `window.globalConfig.WIJAYA_DEV_VERSION` (injected by the `development_version` `enrich_app_config`
  hook) and owns the `Wijaya Dev v…` literal and formatting. The native `shared/store/globalConfig.js`
  is left at the upstream baseline (no marker blocks).

---

## Fail-open summary

| Hook | Native default | Fail mode |
|------|----------------|-----------|
| `apply_team_routing!` | params unchanged | fail open |
| `claim_message_templates!` | `false` (native templates run) | fail open |
| `inbox_marine_assistant_id` | `nil` | fail open |
| `enrich_app_config` | native `config` | fail open |
| route registration | native routes only | fail open, per battery |
| frontend builders/branches | native UI | fail open / native fallthrough |
