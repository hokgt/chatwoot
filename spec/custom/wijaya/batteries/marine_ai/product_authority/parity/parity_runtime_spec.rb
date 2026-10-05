# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2b — the Conversation↔Playground PARITY RUNTIME. It folds each synthetic acceptance case
# through BOTH real surface intakes and the SAME AcceptancePipelineCoordinator per surface, then proves
# PLAN-LAYER parity: PRIMARY = equal normalized actual_outcome across surfaces; reason divergence is
# DIAGNOSTIC ONLY (never fails parity). Acceptance-only, advisory, in-memory; no live wiring.
RSpec.describe 'Marine::ProductAuthority::Parity::Runtime' do
  # Touch IntakeAdapters first so the cohesive intake_adapters.rb (which also defines the sibling
  # Runtime) is loaded before the first Runtime reference — Zeitwerk maps the file to IntakeAdapters.
  adapters = Marine::ProductAuthority::Parity::IntakeAdapters
  runtime = Marine::ProductAuthority::Parity::Runtime
  corpus = Marine::ProductAuthority::Corpus
  case_result_klass = Marine::ProductAuthority::AcceptanceCaseResult
  probe_klass = Marine::ProductAuthority::Evaluator::MutationProbe

  def corpus_case(id)
    Marine::ProductAuthority::Corpus.cases.find { |kase| kase[:id] == id }
  end

  # Build an enum-valid CaseResult carrying a specific reason + a fixed actual/expected outcome, for
  # the reason-diagnostic proof (crafted so two surfaces share an outcome but differ in reason).
  def crafted_result(case_id, surface, reason)
    outcome = { status: 'product', intents: ['price'], slot_ops: ['product'], response_goals: ['answer_price'] }
    Marine::ProductAuthority::AcceptanceCaseResult.build(
      case_id: case_id, surface: surface,
      candidate_plan_status: 'valid', exact_quantity_status: 'clear', adapter_status: 'accepted',
      planner_status: 'planned', repository_revalidation_status: 'revalidated', evidence_packet_status: 'valid',
      expected_outcome: outcome, actual_outcome: outcome, reason: reason, passed: false
    )
  end

  describe 'over the full synthetic corpus' do
    let(:report) { runtime.run }

    it 'folds all 19 cases on both surfaces with full parity' do
      expect(corpus.cases.length).to eq(19)
      expect(report[:schema_version]).to eq('marine_product_authority_parity_run_v1')
      expect(report[:ok]).to be(true)
      expect(report[:total_cases]).to eq(19)
      expect(report[:executed]).to eq(19)
      expect(report[:not_executed]).to eq(0)
      expect(report[:parity_ok_count]).to eq(19)
      expect(report[:parity_failed_ids]).to be_empty
      expect(report[:fail_closed_ids]).to be_empty
      expect(report[:reason_divergence_count]).to eq(0)
    end

    it 'produces an identical normalized actual_outcome across surfaces for every case' do
      report[:case_evidence].each do |entry|
        expect(entry[:conversation].actual_outcome).to eq(entry[:playground].actual_outcome)
      end
    end

    it 'carries two frozen AcceptanceCaseResult objects (one per surface) per case' do
      report[:case_evidence].each do |entry|
        expect(entry[:conversation]).to be_a(case_result_klass).and be_frozen
        expect(entry[:playground]).to be_a(case_result_klass).and be_frozen
        expect(entry[:conversation].surface).to eq('conversation')
        expect(entry[:playground].surface).to eq('playground')
      end
    end

    it 'deep-freezes the report and exposes CaseResult #to_h with the per-case schema' do
      expect(report).to be_frozen
      expect(report[:case_evidence]).to be_frozen
      first = report[:case_evidence].first[:conversation]
      expect(first.to_h[:schema_version]).to eq('marine_product_authority_case_result_v1')
    end
  end

  # PRIMARY CONTRACT PROOF — a lossy intake (drops the variant slot op) for ONE surface on ONE case
  # makes that case's surface outcome diverge, so the primary actual_outcome contract fails parity;
  # every other case stays unaffected (the lossy adapter delegates to the real intake for them).
  describe 'primary contract catches outcome loss' do
    let(:lossy_conversation) do
      Class.new do
        def self.adapt(kase, classification_intents:)
          real = Marine::ProductAuthority::Parity::IntakeAdapters::ConversationIntake
          return real.adapt(kase, classification_intents: classification_intents) unless kase[:id] == 'price_resolved'

          dropped = kase[:plan]['slot_operations'].reject { |op| op['slot'] == 'variant_input' }
          { ok: true, surface: 'conversation',
            input: { plan: kase[:plan].merge('slot_operations' => dropped),
                     scenario_key: kase[:scenario_key] } }
        end
      end
    end

    it 'fails parity only for the lossy case and leaves the rest intact' do
      report = runtime.run(corpus.cases, intakes: { conversation: lossy_conversation, playground: adapters::PlaygroundIntake })

      expect(report[:parity_failed_ids]).to eq(['price_resolved'])
      expect(report[:parity_ok_count]).to eq(18)
      lossy = report[:case_evidence].find { |entry| entry[:id] == 'price_resolved' }
      expect(lossy[:parity_ok]).to be(false)
      expect(lossy[:conversation].actual_outcome).not_to eq(lossy[:playground].actual_outcome)
    end
  end

  # REASON-DIAGNOSTIC PROOF (conditions #2/#3) — when both surfaces reach the SAME actual_outcome but
  # DIFFERENT bounded reasons, parity_ok REMAINS true and only the diagnostic reason divergence is
  # recorded. This is the must-have proof that reason never fails parity by itself.
  describe 'reason divergence is diagnostic only' do
    it 'keeps parity true and records the reason divergence' do
      instance = runtime.new
      allow(instance).to receive(:run_coordinator) do |kase, _input, surface, _qi, _probe|
        reason = surface == 'conversation' ? case_result_klass::REASON_PLANNER_ERROR : case_result_klass::REASON_EVIDENCE_INVALID
        crafted_result(kase[:id], surface, reason)
      end

      report = instance.run([corpus_case('price_resolved')])
      entry = report[:case_evidence].first

      expect(entry[:parity_ok]).to be(true)
      expect(entry[:reasons_agree]).to be(false)
      expect(entry[:reasons]).to eq(conversation: 'planner_error', playground: 'evidence_invalid')
      expect(report[:parity_ok_count]).to eq(1)
      expect(report[:parity_failed_ids]).to be_empty
      expect(report[:reason_divergence_count]).to eq(1)
      expect(report[:reason_divergence_ids]).to eq(['price_resolved'])
    end
  end

  describe 'exact-quantity safety' do
    it 'blocks both surfaces identically and never reads the stock repository' do
      probe = probe_klass.new
      report = runtime.run([corpus_case('exact_quantity_failclosed')], mutation_probe: probe)
      entry = report[:case_evidence].first

      expect(entry[:conversation].exact_quantity_status).to eq('blocked')
      expect(entry[:playground].exact_quantity_status).to eq('blocked')
      expect(entry[:parity_ok]).to be(true)
      expect(probe.reads).to eq(0)
    end
  end

  describe 'quantity-inquiry extractor precedence' do
    it 'lets an injected extractor false beat the corpus safety:true on BOTH folds' do
      # The safety case carries safety.exact_quantity_request == true; the injected canonical
      # extraction false OVERRIDES it on both surfaces, so the fold passes the quantity gate and
      # genuinely reads repositories. The seam-less fold is expressed over the Phase-1 executable
      # intent (price) so the planner really runs against the injected fixtures.
      probe = probe_klass.new
      price_safety = Marshal.load(Marshal.dump(corpus_case('exact_quantity_failclosed'))).tap do |kase|
        kase[:id] = 'syn_price_safety_precedence'
        kase[:plan] = kase[:plan].merge('intents' => ['price'])
        kase[:repositories][:price] = { 'SYN-VAR-ALPHA-01' => Marine::ProductAuthority::Corpus::PRICE_ALPHA }
      end
      report = runtime.run([price_safety],
                           extractor: ->(_kase) { { quantity_inquiry: false } }, mutation_probe: probe)
      entry = report[:case_evidence].first

      expect(entry[:conversation].exact_quantity_status).to eq('clear')
      expect(entry[:playground].exact_quantity_status).to eq('clear')
      expect(probe.reads).to be > 0
    end

    it 'lets an injected extractor true block BOTH folds with zero repository reads' do
      probe = probe_klass.new
      report = runtime.run([corpus_case('price_resolved')],
                           extractor: ->(_kase) { { quantity_inquiry: true } }, mutation_probe: probe)
      entry = report[:case_evidence].first

      expect(entry[:conversation].exact_quantity_status).to eq('blocked')
      expect(entry[:playground].exact_quantity_status).to eq('blocked')
      expect(probe.reads).to eq(0)
    end
  end

  describe 'fault tolerance' do
    it 'skips a non-Hash case as not_executed while keeping the others' do
      report = runtime.run(['not a hash', corpus_case('price_resolved')])

      expect(report[:ok]).to be(true)
      expect(report[:executed]).to eq(1)
      expect(report[:not_executed]).to eq(1)
      expect(report[:case_evidence].first[:id]).to eq('price_resolved')
    end

    it 'captures a per-case bounded internal error when the extractor explodes, leaving others intact' do
      extractor = ->(kase) { raise 'boom' if kase[:id] == 'price_resolved' }
      report = runtime.run([corpus_case('price_resolved'), corpus_case('stock_available')], extractor: extractor)

      expect(report[:ok]).to be(true)
      errored = report[:case_evidence].find { |entry| entry[:id] == 'price_resolved' }
      intact = report[:case_evidence].find { |entry| entry[:id] == 'stock_available' }
      expect(errored[:parity_ok]).to be(false)
      expect(errored[:conversation].reason).to eq('internal_error')
      expect(intact[:parity_ok]).to be(true)
    end

    it 'returns a fail-closed invalid_cases report for a nil or non-Array case set (never raises)' do
      expect(runtime.run(nil)).to include(ok: false, reason: 'invalid_cases')
      expect(runtime.run('x')).to include(ok: false, reason: 'invalid_cases')
      expect(runtime.run(nil)).to be_frozen
    end
  end

  # No-wiring / isolation of the Runtime itself: it reaches the backend ONLY via the Evaluator fakes,
  # and never references the live product/agent runtime constants.
  describe 'the parity runtime is unwired and backend-isolated in source' do
    # Strip comment text (mirroring product_authority_isolation_spec.rb) so only real code references
    # are asserted — the file's own documentation legitimately names these constants.
    let(:code) do
      Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/parity/intake_adapters.rb')
           .read.gsub(/#(?!\{).*/, '')
    end

    %w[Marine::Backend Marine::Agent ProductQueryOrchestrator ShadowMetricsStore CandidateGate].each do |forbidden|
      it "does not reference #{forbidden}" do
        expect(code).not_to include(forbidden)
      end
    end
  end

  # ISOLATION — no live file under the battery app tree (outside the parity folder) references the
  # Parity namespace, mirroring product_authority_isolation_spec.rb.
  describe 'no live battery file references the Parity namespace' do
    it 'confines every Marine::ProductAuthority::Parity reference to the parity folder' do
      root = Rails.root.join('custom/wijaya/batteries/marine_ai/app')
      referencing = Dir[root.join('**/*.rb').to_s]
                    .select { |path| File.read(path).include?('Marine::ProductAuthority::Parity') }
                    .map { |path| Pathname.new(path).relative_path_from(root).to_s }

      expect(referencing).to all(start_with('services/marine/product_authority/parity/'))
    end
  end
end
