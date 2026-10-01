# Fase 3A-2 — FUTURE-FACING, READ-ONLY authority gate for a LATER controlled product-candidate
# rollout. It answers a single question — MAY the Fase 3A-1 backend product outcome be trusted as
# LIVE product authority for this account+assistant RIGHT NOW? — and NOTHING else. It NEVER writes
# config, enables a switch, auto-cuts-over, calls the Runner/provider/adapter/repositories, or mutates
# state.
#
# PHASE LOCK: in Phase 3A-2 live/candidate product authority MUST NEVER open. #open? therefore returns
# false UNCONDITIONALLY — a compile-time guarantee independent of any InstallationConfig value, so no
# operator misconfiguration can promote the candidate to authority in this phase. The phase lock is
# the FIRST statement of #open?, so the future conjunctive logic below is UNREACHABLE from the live
# authority seam. It is advisory and is NOT wired into Marine::Agent::Runner / the live product
# pipeline anywhere.
#
# TESTABILITY (Gap 5): the conjunctive readiness logic a FUTURE (unlocked) phase would use lives in
# the pure, injectable ReadinessPolicy, so it is exercised and asserted DIRECTLY by specs WITHOUT ever
# making the live #open? path reachable. #readiness surfaces that policy's advisory verdict as
# `would_open` (what a future unlocked phase would decide) alongside the explicit `phase_locked` hard
# guarantee; #readiness is advisory ONLY and is never consulted by any execution/response/state/action
# path. The policy opens ONLY when ALL hold, in this order, so a closed config / rollback
# short-circuits BEFORE any metrics read, Runner/provider call, adapter, or repository:
#   1. account_id and assistant_id are positive Integers,
#   2. ShadowConfig.shadow_enabled_for?(assistant_id) — rollback NOT engaged, explicit flag on, id
#      allowlisted (revalidated fresh, so an immediate rollback takes effect on the very next call),
#   3. the candidate mode for the assistant is exactly 'shadow' (an operator has staged it), and
#   4. the advisory ShadowAcceptance report over the 14-day ShadowMetricsStore snapshot is EXACTLY
#      eligible_for_review / thresholds_met.
# Any other outcome, a Redis read error, or any exception closes it. Dependencies are injected for
# tests; there is deliberately NO cache that could delay a rollback.
class Marine::ProductAuthority::CandidateGate
  Config = Marine::ProductAuthority::ShadowConfig
  Store = Marine::ProductAuthority::ShadowMetricsStore
  Acceptance = Marine::ProductAuthority::ShadowAcceptance

  # Phase 3A-2 hard lock: candidate/live product authority never opens this phase.
  PHASE_LOCKED = true

  def initialize(config: Config, store: Store, acceptance: Acceptance, readiness_policy: nil)
    @readiness_policy = readiness_policy || ReadinessPolicy.new(config: config, store: store, acceptance: acceptance)
  end

  def self.open?(account_id:, assistant_id:, **deps)
    new(**deps).open?(account_id: account_id, assistant_id: assistant_id)
  end

  # ALWAYS false in Phase 3A-2 (phase-locked). The phase lock is the first statement, so the future
  # policy below is UNREACHABLE and no config value can open it. Never raises.
  def open?(account_id:, assistant_id:)
    return false if PHASE_LOCKED

    @readiness_policy.ready?(account_id: account_id, assistant_id: assistant_id)
  rescue StandardError
    false
  end

  # Advisory-only readiness for a human reviewer. NEVER consulted by any execution/response/state/
  # action path. `would_open` reflects what a future (unlocked) phase would decide via the pure
  # ReadinessPolicy; `phase_locked` makes the current hard guarantee explicit. Even when `would_open`
  # is true, #open? stays hard false this phase.
  def readiness(account_id:, assistant_id:)
    would_open = @readiness_policy.ready?(account_id: account_id, assistant_id: assistant_id)
    { phase_locked: PHASE_LOCKED, would_open: would_open }.freeze
  rescue StandardError
    { phase_locked: PHASE_LOCKED, would_open: false }.freeze
  end

  # The pure, injectable future-phase readiness policy. It holds the full conjunctive check so it can
  # be tested in isolation WITHOUT reaching the phase-locked live #open? path, and is NEVER consulted
  # by any execution path in this phase. Config (rollback/enable/allowlist) and the staged candidate
  # mode are checked BEFORE the metrics snapshot is ever read, so a rollback or a closed config
  # short-circuits with zero metrics/provider/adapter/repository work.
  # rubocop:disable Style/OneClassPerFile -- the pure readiness policy is the gate's own cohesive
  # testability seam; it belongs with the phase-locked gate, not in a separate file.
  class ReadinessPolicy
    DAYS = Store::MAX_DAYS
    CANDIDATE_MODE_STAGED = 'shadow'.freeze

    def initialize(config: Config, store: Store, acceptance: Acceptance)
      @config = config
      @store = store
      @acceptance = acceptance
    end

    # True ONLY when every conjunctive condition holds. Never raises.
    def ready?(account_id:, assistant_id:)
      return false unless positive_int?(account_id) && positive_int?(assistant_id)
      return false unless @config.shadow_enabled_for?(assistant_id)
      return false unless @config.candidate_mode_for(assistant_id) == CANDIDATE_MODE_STAGED

      eligible?(acceptance_report(account_id, assistant_id))
    rescue StandardError
      false
    end

    private

    def acceptance_report(account_id, assistant_id)
      snapshot = @store.snapshot(account_id: account_id, assistant_id: assistant_id, days: DAYS)
      @acceptance.evaluate(snapshot)
    end

    def eligible?(report)
      report.is_a?(Hash) &&
        report[:status] == Marine::ProductAuthority::ShadowAcceptance::STATUS_ELIGIBLE &&
        report[:reason] == 'thresholds_met'
    end

    def positive_int?(value)
      value.is_a?(Integer) && value.positive?
    end
  end
  # rubocop:enable Style/OneClassPerFile
end
