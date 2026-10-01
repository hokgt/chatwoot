# frozen_string_literal: true

# Fase 3A-2b — CONVERSATION↔PLAYGROUND PARITY RUNTIME (acceptance-only, advisory, in-memory).
#
# This one cohesive file holds the two real-intake projection adapters (ConversationIntake,
# PlaygroundIntake) and the parity fold driver (Runtime). Together they prove PLAN-LAYER PARITY
# through REAL intake shapes: each synthetic acceptance case is projected into a surface-native
# intake envelope, run through the SAME real intake code each live surface uses — the Conversation
# surface validates its envelope through the PUBLIC Marine::Decision::InputContract.build (fail-closed
# reject), the Playground surface bounds its query/history against the PUBLIC
# Marine::Catalog::PlaygroundPreview constants (truncate semantics, mirrored) — and then the case's
# UNCHANGED candidate plan is folded through the canonical AcceptancePipelineCoordinator once per
# surface. Parity is the equality of the two surfaces' NORMALIZED business outcome (actual_outcome);
# the bounded reason is DIAGNOSTIC ONLY and never fails parity by itself.
#
# It is NOT wired into any live runtime path. It is invoked ONLY by a spec or an operator review. It
# proves PLAN-LAYER PARITY via real intake shapes — NOT full end-to-end response parity (that would
# need the forbidden legacy-plan → CandidatePlan converter / full orchestrator run). It NEVER
# generates reply text, calls a presenter / LLM / provider, performs a DB / Redis / settings read,
# mutates a Message/Conversation, hands off, assigns, delivers, or touches ShadowMetricsStore. No
# Shadow is activated. Candidate authority (CandidateGate) is untouched and stays phase-locked.
# Evidence (the live frozen AcceptanceCaseResult objects) is kept IN-MEMORY only; durable retention
# is an explicit, separate, out-of-scope dependency.
#
# ZERO direct backend references live here: the coordinator fold reuses the Evaluator's deterministic
# injection plumbing (its backend class aliases, fixed clock, read-only repository fakes, shared price
# formatter, mutation probe) exactly like the AcceptanceRunner does.
# rubocop:disable Style/OneClassPerFile -- the two intake adapters and the parity fold driver are one
# cohesive acceptance seam (a case is projected by the adapters, then folded by the Runtime); they
# only make sense together and are deliberately kept in a single battery file.
module Marine::ProductAuthority::Parity
  # Acceptance-only REAL-intake envelope projection. Each adapter builds a DETERMINISTIC, fully
  # SYNTHETIC (SYN-*) intake envelope from a corpus case, drives it through the real surface intake
  # code, and — on success — returns the case's plan/scenario/capabilities UNCHANGED for the
  # coordinator fold (plan-layer envelope validation only; NO business conversion). On any intake
  # violation it fails closed to a bounded reason code, never leaking the offending value. Invoked
  # ONLY by specs or operator review; not wired into any live runtime.
  module IntakeAdapters
    Schema = Marine::Decision::Schema
    InputContract = Marine::Decision::InputContract
    PlaygroundPreview = Marine::Catalog::PlaygroundPreview

    # The single bounded intake-rejection code (never the offending value).
    REASON_REJECTED = 'intake_rejected'

    # Conversation surface intake: builds a synthetic bounded envelope and validates it through the
    # REAL Marine::Decision::InputContract.build (the same fail-closed contract the live conversation
    # decision intake uses). A contract violation — oversize/control-heavy message, bad state key,
    # unknown context role, malformed scenario — raises InputContract::Invalid and fails this surface
    # closed. The plan/scenario/capabilities ride UNCHANGED to the coordinator.
    class ConversationIntake
      SURFACE = 'conversation'

      def self.adapt(kase)
        contract = InputContract.build(
          message: synthetic_message(kase),
          context: context(kase),
          state: state(kase),
          scenarios: scenarios(kase)
        )
        # Defensive: the real contract must have accepted the case's own scenario key.
        return failure unless Array(contract[:scenario_keys]).include?(kase[:scenario_key])

        success(kase)
      rescue InputContract::Invalid
        failure
      end

      # A deterministic, fully-synthetic, control-clean customer turn derived from the case: its id,
      # its candidate intents, and a summary of its slot operations. Bounded well within the
      # contract's MAX_MESSAGE_CHARS. Shared verbatim with the Playground surface query.
      def self.synthetic_message(kase)
        intents = plan_intents(kase).join(',')
        slots = Array(kase.dig(:plan, 'slot_operations')).filter_map { |op| slot_summary(op) }.join(',')
        "SYN-PARITY #{kase[:id]} intents=#{intents} slots=#{slots}"
      end

      def self.slot_summary(operation)
        return nil unless operation.is_a?(Hash)

        "#{operation['operation']}:#{operation['slot']}"
      end

      # No prior turns are projected — the acceptance envelope is a single synthetic turn.
      def self.context(_kase)
        []
      end

      # Coarse candidate-only state hints: the selected scenario, plus the first candidate intent when
      # it is a real Schema::INTENTS member. Nothing validated/factual is ever carried.
      def self.state(kase)
        hints = { 'current_scenario' => kase[:scenario_key] }
        intent = plan_intents(kase).find { |code| Schema::INTENTS.include?(code) }
        hints['current_intent'] = intent if intent
        hints
      end

      # A single synthetic scenario entry with the case's own capability list (exact contract keys).
      def self.scenarios(kase)
        [{
          'key' => kase[:scenario_key],
          'description' => 'synthetic acceptance scenario',
          'instruction' => 'synthetic acceptance instruction',
          'capabilities' => Array(kase.dig(:capabilities, kase[:scenario_key]))
        }]
      end

      def self.plan_intents(kase)
        Array(kase.dig(:plan, 'intents')).select { |code| code.is_a?(String) }
      end

      def self.success(kase)
        { ok: true, surface: SURFACE, input: IntakeAdapters.case_input(kase) }
      end

      def self.failure
        { ok: false, surface: SURFACE, reason: REASON_REJECTED }
      end
    end

    # Playground surface intake: mirrors the live preview intake bounds using ONLY the PUBLIC
    # PlaygroundPreview constants. The query is the SAME deterministic synthetic message string (must
    # be a non-blank String); history is empty and state_token is nil (a fresh flow — no token
    # machinery, no assistant/account). `bounded_history` mirrors PlaygroundPreview's private
    # bounded_history semantics for any supplied history (equivalence is proven in a spec). On a
    # blank/non-String query it fails closed.
    class PlaygroundIntake
      SURFACE = 'playground'

      def self.adapt(kase)
        query = ConversationIntake.synthetic_message(kase)
        return failure unless query.is_a?(String) && !query.strip.empty?

        { ok: true, surface: SURFACE, input: IntakeAdapters.case_input(kase) }
      end

      # Mirror of Marine::Catalog::PlaygroundPreview#bounded_history using only its PUBLIC constants:
      # drop blank content and roles outside HISTORY_ROLES, TRUNCATE each turn to MAX_TURN_CHARS, keep
      # the last MAX_HISTORY_TURNS (oldest-to-newest order preserved). Divergence from the live surface
      # here is intake TRUNCATION — the deliberate counterpart to the Conversation surface's REJECT.
      def self.bounded_history(history)
        Array(history).filter_map do |turn|
          role = (turn[:role] || turn['role']).to_s
          content = (turn[:content] || turn['content']).to_s.strip
          next if content.empty? || PlaygroundPreview::HISTORY_ROLES.exclude?(role)

          { role: role, content: content[0, PlaygroundPreview::MAX_TURN_CHARS] }
        end.last(PlaygroundPreview::MAX_HISTORY_TURNS)
      end

      def self.failure
        { ok: false, surface: SURFACE, reason: REASON_REJECTED }
      end
    end

    # The UNCHANGED coordinator input shared by both surfaces (plan-layer projection, no conversion).
    def self.case_input(kase)
      { plan: kase[:plan], scenario_key: kase[:scenario_key], capabilities: kase[:capabilities] }
    end
  end

  # Parity fold driver. For every executable corpus case it resolves the exact-quantity boolean ONCE
  # (mirroring the AcceptanceRunner's canonical precedence), projects the case through BOTH surface
  # intakes, and folds the UNCHANGED plan through a FRESH AcceptancePipelineCoordinator per surface
  # (reusing the Evaluator's DB-free injection plumbing). It derives a bounded, deep-frozen aggregate
  # report from ONLY the resulting AcceptanceCaseResults. It NEVER raises.
  #
  # PARITY CONTRACT: PRIMARY = conversation.actual_outcome == playground.actual_outcome (normalized
  # business outcome). The bounded reason is DIAGNOSTIC ONLY — recorded as a pair plus an agreement
  # flag and divergence aggregate, but a reason difference NEVER fails parity by itself. Per-surface
  # pass? (label conformance) is a recorded secondary signal.
  class Runtime # rubocop:disable Metrics/ClassLength -- one cohesive advisory fold driver: executable gate, per-surface fold, quantity precedence, per-case evidence, and the derived aggregate belong to one seam
    Corpus = Marine::ProductAuthority::Corpus
    Coordinator = Marine::ProductAuthority::AcceptancePipelineCoordinator
    CaseResult = Marine::ProductAuthority::AcceptanceCaseResult
    Outcome = Marine::ProductAuthority::ProductOutcome

    # Reuse the Evaluator's deterministic acceptance plumbing verbatim (its backend class aliases,
    # fixed clock, injectable mutation probe, and read-only repository / price-formatter fakes), so
    # this driver holds NO direct backend reference of its own — exactly like AcceptanceRunner.
    Fakes = Marine::ProductAuthority::Evaluator
    Planner = Fakes::Planner
    EvidenceBuilder = Fakes::EvidenceBuilder
    FIXED_CLOCK = Fakes::FIXED_CLOCK

    SCHEMA_VERSION = 'marine_product_authority_parity_run_v1'
    CONVERSATION_SURFACE = 'conversation'
    PLAYGROUND_SURFACE = 'playground'

    # Default real intake adapters; injectable (one keyword) so a spec can supply a lossy/crafted
    # adapter for a single surface to prove the primary contract catches outcome loss.
    DEFAULT_INTAKES = {
      conversation: IntakeAdapters::ConversationIntake,
      playground: IntakeAdapters::PlaygroundIntake
    }.freeze

    # The bounded fallback outcome for the defensive internal-error CaseResult (status unknown, empty
    # closed lists) — used only when the per-case rescue fires, never on a well-formed executable case.
    UNKNOWN_OUTCOME = { status: Outcome::STATUS_UNKNOWN, intents: [], slot_ops: [], response_goals: [] }.freeze

    def self.run(cases = Corpus.cases, extractor: nil, mutation_probe: nil, intakes: nil)
      new.run(cases, extractor: extractor, mutation_probe: mutation_probe, intakes: intakes)
    end

    # A deep-frozen advisory parity report over the given case set. Never raises. `extractor` is the
    # injectable canonical quantity-inquiry seam; `mutation_probe` the injectable observer; `intakes`
    # the injectable per-surface intake adapters.
    def run(cases = Corpus.cases, extractor: nil, mutation_probe: nil, intakes: nil)
      return invalid_report('invalid_cases') unless cases.is_a?(Array)

      probe = mutation_probe || Fakes::MutationProbe.new
      adapters = intakes || DEFAULT_INTAKES
      evidence = []
      not_executed = 0
      cases.each do |kase|
        if executable_case?(kase)
          evidence << run_case(kase, extractor, probe, adapters)
        else
          not_executed += 1
        end
      end
      report(evidence, not_executed, cases.length)
    rescue StandardError
      invalid_report('run_error')
    end

    private

    # The structural minimum a case needs to be folded at all — identical to the AcceptanceRunner's
    # gate. A non-Hash entry or a missing/invalid id / non-Hash plan/label/repositories/capabilities /
    # non-String scenario_key is skipped as not_executed WITHOUT a result.
    def executable_case?(kase)
      kase.is_a?(Hash) && CaseResult.valid_case_id?(kase[:id]) &&
        kase[:plan].is_a?(Hash) && kase[:label].is_a?(Hash) &&
        kase[:repositories].is_a?(Hash) && kase[:capabilities].is_a?(Hash) &&
        kase[:scenario_key].is_a?(String)
    end

    # Fold ONE executable case through BOTH surfaces. The mutation probe is noted ONCE per case
    # (shared across both folds) and the exact-quantity boolean is resolved ONCE and passed to BOTH
    # folds, so the safety short-circuit is identical across surfaces. Any unexpected exception (e.g.
    # an exploding injected extractor) is captured as bounded internal-error evidence so other cases
    # keep their results.
    def run_case(kase, extractor, probe, adapters)
      probe.note_run
      quantity_inquiry = resolve_quantity_inquiry(kase, extractor)
      conversation = fold_surface(kase, adapters[:conversation], CONVERSATION_SURFACE, quantity_inquiry, probe)
      playground = fold_surface(kase, adapters[:playground], PLAYGROUND_SURFACE, quantity_inquiry, probe)
      case_evidence(kase, conversation, playground)
    rescue StandardError
      internal_error_evidence(kase)
    end

    # Project the case through one surface intake, then fold its UNCHANGED plan through the
    # coordinator. A fail-closed intake returns nil (no fold on that surface); the other surface is
    # still folded and recorded.
    def fold_surface(kase, adapter, surface, quantity_inquiry, probe)
      adapted = adapter.adapt(kase)
      return nil unless adapted.is_a?(Hash) && adapted[:ok]

      run_coordinator(kase, adapted[:input], surface, quantity_inquiry, probe)
    end

    # Canonical source precedence (mirrors AcceptanceRunner): an injected canonical extraction result
    # (a Hash with a boolean :quantity_inquiry) wins; otherwise fall back to the corpus
    # safety.exact_quantity_request evaluation metadata. Text is NEVER parsed.
    def resolve_quantity_inquiry(kase, extractor)
      canonical = canonical_quantity_inquiry(kase, extractor)
      return canonical unless canonical.nil?

      safety_fallback(kase)
    end

    def canonical_quantity_inquiry(kase, extractor)
      return nil if extractor.nil?

      result = extractor.call(kase)
      return nil unless result.is_a?(Hash)

      value = result[:quantity_inquiry]
      [true, false].include?(value) ? value : nil
    end

    def safety_fallback(kase)
      safety = kase[:safety]
      safety.is_a?(Hash) && safety[:exact_quantity_request] == true
    end

    # Fold ONE surface's UNCHANGED plan through a FRESH AcceptancePipelineCoordinator with the SAME
    # DB-free injection pattern the Evaluator/AcceptanceRunner use: the case's read-only repository
    # fakes + the shared mutation probe, and ONE shared deterministic price formatter + the FIXED_CLOCK
    # across planner and evidence builder. The real surface is tagged (`conversation`/`playground`).
    def run_coordinator(kase, input, surface, quantity_inquiry, probe)
      formatter = Fakes::FakePriceFormatter.new
      Coordinator.new(
        planner: Planner.new(**planner_repositories(kase, probe, formatter)),
        evidence_builder: EvidenceBuilder.new(clock: FIXED_CLOCK, price_formatter: formatter)
      ).run(
        candidate_plan: input[:plan],
        scenario_key: input[:scenario_key],
        scenario_capabilities: input[:capabilities],
        quantity_inquiry: quantity_inquiry,
        case_id: kase[:id],
        surface: surface,
        expected_outcome: expected_outcome(kase[:label])
      )
    end

    def planner_repositories(kase, probe, formatter)
      repos = kase[:repositories]
      {
        family_repository: Fakes::FakeFamilyRepository.new(repos[:family] || {}, probe),
        variant_resolver: Fakes::FakeVariantResolver.new(repos[:variant] || {}, probe),
        price_repository: Fakes::FakePriceRepository.new(repos[:price] || {}, probe),
        stock_repository: Fakes::FakeStockRepository.new(repos[:stock] || {}, probe),
        price_formatter: formatter,
        clock: FIXED_CLOCK
      }
    end

    # Project the case label into the coordinator's canonical expected-outcome shape (a blocked
    # label's nil/absent lists become the canonical empty arrays the closed outcome requires).
    def expected_outcome(label)
      { status: label[:status], intents: label[:intents] || [], slot_ops: label[:slot_ops] || [],
        response_goals: label[:response_goals] || [] }
    end

    # Build the per-case evidence entry. PRIMARY parity = both surfaces folded AND their normalized
    # actual_outcome is equal. A fail-closed intake on either surface marks that surface and fails
    # parity for the case. The reason pair + agreement flag are DIAGNOSTIC ONLY.
    def case_evidence(kase, conversation, playground)
      fail_closed = fail_closed_surface(conversation, playground)
      parity_ok = fail_closed.nil? && conversation.actual_outcome == playground.actual_outcome
      {
        id: kase[:id],
        parity_ok: parity_ok,
        reasons_agree: reason_of(conversation) == reason_of(playground),
        reasons: { conversation: reason_of(conversation), playground: reason_of(playground) },
        passed: { conversation: pass_of(conversation), playground: pass_of(playground) },
        fail_closed: fail_closed,
        conversation: conversation,
        playground: playground
      }
    end

    def fail_closed_surface(conversation, playground)
      return CONVERSATION_SURFACE if conversation.nil?
      return PLAYGROUND_SURFACE if playground.nil?

      nil
    end

    def reason_of(result)
      result&.reason
    end

    def pass_of(result)
      result&.pass? || false
    end

    # Bounded internal-error evidence for the defensive per-case rescue only: both surfaces carry a
    # skipped-stage internal_error CaseResult (reasons agree, but parity is false — an errored case is
    # never a parity pass), so other cases keep their results and the run stays ok.
    def internal_error_evidence(kase)
      conversation = internal_error_case_result(kase, CONVERSATION_SURFACE)
      playground = internal_error_case_result(kase, PLAYGROUND_SURFACE)
      {
        id: safe_id(kase),
        parity_ok: false,
        reasons_agree: true,
        reasons: { conversation: conversation.reason, playground: playground.reason },
        passed: { conversation: false, playground: false },
        fail_closed: nil,
        conversation: conversation,
        playground: playground
      }
    end

    # A bounded internal-error AcceptanceCaseResult built WITHOUT re-running the pipeline (all stages
    # skipped), mirroring the coordinator's own internal_error shape so the per-case evidence stays
    # uniform and leaks no exception text.
    def internal_error_case_result(kase, surface)
      CaseResult.build(
        case_id: safe_id(kase),
        surface: surface,
        candidate_plan_status: 'skipped', exact_quantity_status: 'skipped', adapter_status: 'skipped',
        planner_status: 'skipped', repository_revalidation_status: 'skipped', evidence_packet_status: 'skipped',
        expected_outcome: UNKNOWN_OUTCOME, actual_outcome: UNKNOWN_OUTCOME,
        reason: CaseResult::REASON_INTERNAL_ERROR, passed: false
      )
    end

    def safe_id(kase)
      id = kase.is_a?(Hash) ? kase[:id] : nil
      CaseResult.valid_case_id?(id) ? id : 'unknown_case'
    end

    # The aggregate report, DERIVED ONLY from the per-case evidence (each entry carries the live frozen
    # AcceptanceCaseResults the coordinator emitted). reason_divergence counts ONLY fully-folded cases
    # whose reasons differ — a diagnostic signal that never affects parity_ok. Deep-freezing leaves
    # each already-frozen CaseResult intact (never replaced by its to_h), so contract identity holds.
    def report(evidence, not_executed, total_cases)
      deep_freeze(
        schema_version: SCHEMA_VERSION,
        ok: true,
        total_cases: total_cases,
        executed: evidence.length,
        not_executed: not_executed,
        parity_ok_count: evidence.count { |entry| entry[:parity_ok] },
        parity_failed_ids: ids(evidence.reject { |entry| entry[:parity_ok] }),
        fail_closed_ids: ids(evidence.select { |entry| entry[:fail_closed] }),
        reason_divergence_count: reason_divergent(evidence).length,
        reason_divergence_ids: ids(reason_divergent(evidence)),
        both_passed_count: evidence.count { |entry| both_passed?(entry) },
        case_evidence: evidence
      )
    end

    # Only fully-folded cases (no fail-closed intake) whose bounded reasons differ — a diagnostic
    # signal that never affects parity_ok.
    def reason_divergent(evidence)
      evidence.select { |entry| entry[:fail_closed].nil? && !entry[:reasons_agree] }
    end

    def both_passed?(entry)
      entry[:passed][:conversation] && entry[:passed][:playground]
    end

    def ids(entries)
      entries.pluck(:id)
    end

    def invalid_report(reason)
      deep_freeze(
        schema_version: SCHEMA_VERSION, ok: false, reason: reason,
        total_cases: 0, executed: 0, not_executed: 0,
        parity_ok_count: 0, parity_failed_ids: [], fail_closed_ids: [],
        reason_divergence_count: 0, reason_divergence_ids: [], both_passed_count: 0, case_evidence: []
      )
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |child| deep_freeze(child) }
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
# rubocop:enable Style/OneClassPerFile
