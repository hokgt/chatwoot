# READ-ONLY, fail-closed authority gate for the Marine Decision Maker scenario-selection cutover
# (Phase 2 / Stage 6). It answers a single question — MAY the Decision Maker's scenario choice be
# trusted as backend authority for this account+assistant RIGHT NOW? — and NOTHING else. It NEVER
# writes config, enables a switch, auto-cuts-over, calls the Runner/provider, or mutates state.
#
# It opens ONLY when ALL of the following hold, in this order:
#   1. account_id and assistant_id are positive Integers,
#   2. Marine::Decision::CutoverConfig.enabled_for?(assistant_id) is true — so rollback / a closed
#      config / a missing allowlist / a stopped shadow short-circuit BEFORE any metrics read, and
#   3. the ADVISORY Marine::Decision::ShadowAcceptance report over the last 14 daily
#      Marine::Decision::ShadowMetricsStore counters is EXACTLY
#      status == eligible_for_review AND reason == thresholds_met.
#
# Any other acceptance outcome (insufficient_data, hold, invalid_snapshot, a malformed report),
# a Redis read error, or any exception closes the gate (returns false). Config being closed means
# the metrics snapshot is NEVER read, so a rollback takes effect on the very next call with zero
# provider/metrics work. Dependencies are injected for tests; there is deliberately NO cache that
# could delay a rollback.
class Marine::Decision::CutoverGate
  Config = Marine::Decision::CutoverConfig
  Store = Marine::Decision::ShadowMetricsStore
  Acceptance = Marine::Decision::ShadowAcceptance

  # Fixed acceptance window: the store's full retention window of daily counters.
  DAYS = Store::MAX_DAYS

  # The gate opens ONLY on this exact eligible report; every other status/reason closes it.
  ELIGIBLE_STATUS = Acceptance::STATUS_ELIGIBLE
  ELIGIBLE_REASON = 'thresholds_met'.freeze

  def initialize(config: Config, store: Store, acceptance: Acceptance)
    @config = config
    @store = store
    @acceptance = acceptance
  end

  def self.open?(account_id:, assistant_id:, **deps)
    new(**deps).open?(account_id: account_id, assistant_id: assistant_id)
  end

  # True ONLY when the config is open for this assistant AND the advisory acceptance report is the
  # exact eligible/thresholds_met verdict. Never raises; any anomaly closes the gate. When the
  # config is closed the metrics snapshot is never read (so rollback is immediate).
  def open?(account_id:, assistant_id:)
    return false unless positive_int?(account_id) && positive_int?(assistant_id)
    return false unless @config.enabled_for?(assistant_id)

    eligible?(acceptance_report(account_id, assistant_id))
  rescue StandardError
    false
  end

  private

  # The advisory acceptance report over the bounded metrics snapshot. Reads ONLY the snapshot;
  # never writes, never enables.
  def acceptance_report(account_id, assistant_id)
    snapshot = @store.snapshot(account_id: account_id, assistant_id: assistant_id, days: DAYS)
    @acceptance.evaluate(snapshot)
  end

  # The report must be EXACTLY the eligible/thresholds_met verdict; anything else fails closed.
  def eligible?(report)
    report.is_a?(Hash) &&
      report[:status] == ELIGIBLE_STATUS &&
      report[:reason] == ELIGIBLE_REASON
  end

  def positive_int?(value)
    value.is_a?(Integer) && value.positive?
  end
end
