# frozen_string_literal: true

# The deferred-auto-assignment MarkerDropTrigger keeps the reconciliation run ledger's terminal
# counters truthful when a DB cascade removes a reconciliation-owned marker with no Rails callback
# (see MarkerDropTrigger). In production it is installed by migration 20260912000008 (migrate-forward)
# and re-asserted on boot by the battery loader (fresh db:schema:load installs). A CI/test database
# built purely from schema.rb via db:schema:load may not carry it yet, so re-assert it once,
# idempotently, AFTER maintain_test_schema! has (re)loaded the schema — before any example runs — so
# every deferred-auto-assignment spec exercises the same trigger production carries.
RSpec.configure do |config|
  config.before(:suite) do
    Wijaya::Batteries::DeferredAutoAssignment::MarkerDropTrigger.install!
  end
end
