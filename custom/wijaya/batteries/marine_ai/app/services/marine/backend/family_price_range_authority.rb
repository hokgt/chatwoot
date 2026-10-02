# Phase 2A (PRICE-ONLY shadow bridge) — a THIN, read-only authority wrapper over the existing
# Marine::Catalog::PriceRangeRepository#range_for. It is reached only for an EXACT current family
# with no resolved child (and no exact-child ambiguity / revalidation conflict), to ground the
# family-level price RANGE. It performs no provider call, no state write, and has no runtime wiring.
#
# It emits a bounded, immutable canonical internal result. The repository returns the exact-decimal
# range tuple; this wrapper only stamps the non-LLM `source` and `checked_at` and maps the
# fail-closed statuses. The range is an INTERNAL canonical structure in 2A — it is never added to
# marine_evidence_v1 and never reaches a customer.
class Marine::Backend::FamilyPriceRangeAuthority
  SOURCE = 'catalog_price_range_repository'.freeze

  STATUS_AVAILABLE = :available
  # The repository's :unavailable/:conflict both map to a single fail-closed range_unavailable; a
  # catalog outage maps to :outage so the coordinator can distinguish it as catalog_unavailable.
  STATUS_RANGE_UNAVAILABLE = :range_unavailable
  STATUS_OUTAGE = :outage

  # Closed, immutable canonical range. min/max/currency/uom are present only for :available. The
  # :min/:max members deliberately expose the canonical range endpoints as the public contract
  # (result.min / result.max); the StructNewOverride lint is disabled narrowly on this line alone
  # because shadowing Enumerable#min/#max with the range endpoints is the intended, documented API.
  Result = Struct.new(:status, :min, :max, :currency, :uom, :source, :checked_at, keyword_init: true) do # rubocop:disable Lint/StructNewOverride
    def available? = status == STATUS_AVAILABLE
  end

  def initialize(price_range_repository: nil, clock: nil)
    @price_range_repository = price_range_repository || Marine::Catalog::PriceRangeRepository.new
    @clock = clock || -> { Time.current }
  end

  def call(family_code:)
    range = @price_range_repository.range_for(family_code)
    range[:status] == :available ? available(range) : fail_closed(STATUS_RANGE_UNAVAILABLE)
  rescue Marine::Catalog::Errors::CatalogUnavailableError
    fail_closed(STATUS_OUTAGE)
  end

  private

  def available(range)
    build(
      status: STATUS_AVAILABLE,
      min: range[:min], max: range[:max], currency: range[:currency], uom: range[:uom]
    )
  end

  def fail_closed(status)
    build(status: status)
  end

  # Stamp the adapter-owned source/checked_at and deep-freeze. Repository amount strings AND the
  # stamped checked_at string are frozen so the canonical result is fully (recursively) immutable.
  def build(status:, min: nil, max: nil, currency: nil, uom: nil)
    available = status == STATUS_AVAILABLE
    Result.new(
      status: status, min: freeze_string(min), max: freeze_string(max),
      currency: freeze_string(currency), uom: freeze_string(uom),
      source: (SOURCE if available), checked_at: freeze_string(available ? now_iso8601 : nil)
    ).freeze
  end

  def now_iso8601 = @clock.call.utc.iso8601

  def freeze_string(value)
    value.is_a?(String) ? value.dup.freeze : value
  end
end
