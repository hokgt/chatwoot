# Marine Product Authority — Fase 3A-2b: Conversation–Playground Parity Runtime

> **For Hermes:** Plan APPROVED by Pak Ahok with the 7 conditions listed below. This file is the authoritative implementation source.

**Goal:** Runtime parity acceptance Conversation-vs-Playground yang nyata (bukan hanya synthetic envelope harness) dengan tetap acceptance-only, advisory, tanpa mengubah behavior live mana pun.

**Architecture:** Battery-isolated, zero wiring ke live runtime. Dua **intake adapter** nyata — Conversation (validasi via `Marine::Decision::InputContract.build` PUBLIC API, fail-closed reject) dan Playground (bounds via konstanta publik `PlaygroundPreview`, mirror semantics truncation) — memproyeksikan case acceptance (plan v1 unchanged) melewati kode intake nyata masing-masing surface, lalu plan di-fold lewat `AcceptancePipelineCoordinator` yang sama per surface. Parity = **`actual_outcome` identik antar surface (PRIMARY)**; `reason` = diagnostic/secondary. Tanpa pipeline kedua, tanpa schema per-case kedua.

## 7 syarat APPROVE (Pak Ahok) — mengikat implementasi

1. Implementasi sesuai file plan ini.
2. **`actual_outcome` = primary parity contract** (equality antar surface).
3. **`reason` = diagnostic/secondary evidence** — dicatat (reason pair + agree flag + divergence count), TIDAK pernah membuat parity gagal sendirian.
4. **Tidak ada legacy-plan → CandidatePlan converter.**
5. **Tidak mengubah Evaluator, Runner, Coordinator, CaseResult, Corpus, CandidateGate** (hanya file baru + registry).
6. **Tidak mengaktifkan Shadow / tidak menghubungkan live runtime** (spec/operator-only, in-memory, advisory).
7. Report akhir menyatakan eksplisit: yang terbukti adalah **plan-layer parity melalui real intake shapes**, bukan full end-to-end response parity.

## Grounding (fakta kode terverifikasi)

- `AcceptancePipelineCoordinator.run(candidate_plan:, scenario_key:, scenario_capabilities:, quantity_inquiry:, case_id:, surface:, expected_outcome:)` → frozen `AcceptanceCaseResult`; `quantity_inquiry==true` short-circuit blocked sebelum adapter/planner; `CaseResult::SURFACES = %w[conversation playground evaluator]` — surface `conversation`/`playground` **sudah valid** di contract.
- `AcceptanceCaseResult` (satu-satunya schema per-case: `marine_product_authority_case_result_v1`): `actual_outcome` (normalized `{status:, intents:, slot_ops:, response_goals:}`), `reason` (vocabulary tertutup), `pass?`, `to_h`.
- `AcceptanceRunner` = pola injection yang di-mirror: `Fakes = Marine::ProductAuthority::Evaluator` (Planner, EvidenceBuilder, FIXED_CLOCK, fake repos, FakePriceFormatter, MutationProbe); quantity precedence = extractor canonical (Hash dengan boolean `:quantity_inquiry`) > `safety.exact_quantity_request`; `expected_outcome` dari label. Runner **frozen** (syarat #5) — pola di-mirror, bukan diedit.
- `Corpus.cases` = 19 case synthetic: `{id, category, critical, surface, scenario_key, capabilities, plan (string-keyed marine_decision_v1), repositories, label, optional safety, optional parity}`.
- `Marine::Decision::InputContract.build(message:, context:, state:, scenarios:)` — PUBLIC, raise `Invalid` fail-closed (bounds: message ≤2000 chars/8000 bytes **reject bukan truncate**; context ≤10 × {role ∈ [user,assistant], content ≤2000}; state allowlist `STATE_KEYS`; scenario entry keys exact `%w[key description instruction capabilities]`).
- `Marine::Catalog::PlaygroundPreview`: konstanta publik `MAX_HISTORY_TURNS=10`, `MAX_TURN_CHARS=500`, `HISTORY_ROLES=%w[user assistant]`; private `bounded_history` — **truncate** ke 500 + keep last 10 + filter role/blank; query non-blank; state_token nil → fresh flow. Private method TIDAK dipanggil dari production code — semantics di-mirror via konstanta publik, **equivalence dengan metode asli dibuktikan di spec** (send spec-only).
- Perbedaan semantik nyata antar surface (harus tercermin di adapter): Conversation **menolak** oversize (reject), Playground **memotong** (truncate). Ini divergensi intake nyata yang parity runtime harus mampu tunjukkan.

## Keputusan desain

- **Envelope synthetic dibangun dari case** (deterministik, hanya token SYN-*): message/query = string bounded dari case id + intents + ringkasan slot ops; context/history = []; state = `{'current_scenario' => scenario_key}` (+ `current_intent` bila intent valid); scenarios = [{key, description, instruction, capabilities}] — lalu **diveowati kode intake nyata** (Conversation: `InputContract.build` asli; Playground: mirror `bounded_history` + non-blank query). Plan/scenario/capabilities rides **unchanged** ke coordinator (plan-layer projection; bukan konversi bisnis — syarat #4).
- **Quantity resolved SEKALI per case** (mirror precedence runner) dan nilai boolean sama dipakai untuk **kedua** fold surface — short-circuit safety identik antar surface.
- **Fold per surface** melalui Coordinator fresh per fold (pola injection runner persis; probe `note_run` sekali per case; formatter shared per fold; FIXED_CLOCK), dengan `surface:` masing-masing nyata (`conversation`/`playground`).
- **Parity per case**: PRIMARY `conv_result.actual_outcome == play_result.actual_outcome`. Diagnostic: `reasons` pair + `reasons_agree` + divergence aggregate. Tambahan sinyal: per-surface `pass?` (konformansi label) — tercatat, tidak menggantikan contract utama.
- **Intake fail-closed** di satu surface → `parity_ok=false` untuk case itu + marker `fail_closed` bounded (tidak ada fold di surface itu); surface lain tetap dievaluasi.
- **Aggregate report** derived HANYA dari CaseResult: `marine_product_authority_parity_run_v1` — `{ok, total_cases, executed, not_executed, parity_ok_count, parity_failed_ids, fail_closed_ids, reason_divergence_count, reason_divergence_ids, both_passed_count, case_evidence[{id, parity_ok, reasons_agree, reasons{...}, passed{...}, fail_closed, conversation: CaseResult|nil, playground: CaseResult|nil}]}` — deep-frozen, in-memory (retention permanen tetap dependency terpisah). Case tidak valid struktural → skipped `not_executed` (mirror runner); rescue per case → internal-error bounded.
- **Zero referensi langsung `Marine::Backend`** (hanya via alias Fakes Evaluator, seperti runner). Tidak ada provider call/DB/Redis/settings/reply/mutasi.

## Files (persis)

- **Create** `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/parity/intake_adapters.rb` — satu file cohesive: `Marine::ProductAuthority::Parity::IntakeAdapters::ConversationIntake`, `...::PlaygroundIntake`, `Marine::ProductAuthority::Parity::Runtime` (fold driver + aggregate report). Class comment wajib menyatakan: not wired anywhere, spec/operator-only, plan-layer parity via real intake shapes (bukan full end-to-end response parity), in-memory.
- **Create** `spec/custom/wijaya/batteries/marine_ai/product_authority/parity/intake_adapters_spec.rb` — round-trip real `InputContract` (valid, oversize reject, bad state key, control-heavy, unknown role); playground ok/blank-query/truncate-500/last-10/role-filter; **mirror-equivalence spec** vs `PlaygroundPreview#bounded_history` asli (send, spec-only).
- **Create** `spec/custom/wijaya/batteries/marine_ai/product_authority/parity/parity_runtime_spec.rb` — 19 case × 2 surface = 38 fold semua parity_ok; **lossy stub intake** (drop slot op) → parity gagal (bukti primary contract menangkap loss); **reason-divergence test**: outcome sama + reason beda → parity_ok TETAP true + divergence tercatat (membuktikan syarat #2/#3); exact-quantity: kedua surface blocked identik + stock reads 0; extractor canonical > safety fallback di KEDUA fold; case non-Hash skipped; extractor meledak → internal-error bounded, case lain utuh; invalid case set → `ok:false invalid_cases`; case_evidence = objek CaseResult v1 frozen; isolation: tidak ada file live yang mereferensikan `Marine::ProductAuthority::Parity` (align dengan pola `product_authority_isolation_spec.rb`).
- **Modify** `custom/wijaya/patches/patch_registry.yml` — 3 entri file baru (style: entri acceptance runner commit `7deea3d580`).
- Tidak ada file lain yang disentuh.

## Tasks (TDD, bite-sized)

1. **Conversation intake adapter** — failing test round-trip + fail-closed → implement (real `InputContract.build`) → pass.
2. **Playground intake adapter** — failing test (blank query, truncate, last-10, role filter, mirror-equivalence) → implement (mirror via konstanta publik) → pass.
3. **Parity Runtime** — failing test (38 fold, lossy-stub gagal, reason-divergence tetap ok, exact-quantity reads 0, extractor precedence, skip/rescue/invalid-set, isolation) → implement fold driver + aggregate → pass.
4. **Registry + verifikasi penuh** — registry 3 entri → `check_custom_patches.sh` OK → full `product_authority/` + `backend_pipeline_integration_spec.rb` hijau (baseline 293 examples tetap pass) → RuboCop bersih → `git diff --check`.

## Verifikasi

```bash
WIJAYA_TEST_SERVICE=vite custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh bundle exec rspec spec/custom/wijaya/batteries/marine_ai/product_authority/parity/ -fd
WIJAYA_TEST_SERVICE=vite custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh bundle exec rspec spec/custom/wijaya/batteries/marine_ai/product_authority/ spec/custom/wijaya/batteries/marine_ai/backend/backend_pipeline_integration_spec.rb -fd
bash custom/wijaya/scripts/check_custom_patches.sh
bundle exec rubocop <3 file>
# runtime probe advisory di container (post-deploy): Parity::Runtime.run → report bounded; invariants: gate locked, shadow off
```

## Risks / Tradeoffs

- **Plan-layer parity** (syarat #7 diakui eksplisit): envelope intake nyata, payload plan unchanged — bukan full legacy-pipeline parity (butuh converter terlarang). Jika acceptance 50/30 nanti menyurutkan layer tambahan → fase terpisah.
- Mirror `bounded_history` vs private asli — mitigasi: spec equivalence (send spec-only); upstream berubah → spec merah → mirror diperbaiki.
- Duplikasi kecil precedence quantity (Runner frozen, syarat #5) — didokumentasikan sebagai mirror dari runner.
- Evidence in-memory (retention tetap roadmap terpisah).
- Conversation adapter tidak memanggil provider LLM — konsisten acceptance DB-free/network-free.

## Out of scope (dilarang)

Mutation-proof → ReadinessPolicy wiring; campaign 50/30; ShadowExecution live trigger; Gate C; ERP; UI; dataset tester; converter legacy-plan→v1; edit Evaluator/Runner/Coordinator/CaseResult/Corpus/gate; mengaktifkan Shadow.
