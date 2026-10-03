# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — proves the PRODUCT-authority path is ISOLATED and advisory: the LIVE product pipeline has
# ZERO references to Marine::Backend; the ONLY runtime consumers of Marine::Backend under the battery
# are the product-authority ShadowExecution and Evaluator (plus the Marine::Backend services
# themselves); the shadow enqueuer/job/execution perform no persistence; the ShadowExecution is
# adapter-only; and the CandidateGate is phase-locked closed. This is a static, deterministic source
# assertion plus one runtime lock check.
RSpec.describe 'Marine::ProductAuthority Fase 3A-2 isolation' do
  root = Rails.root.join('custom/wijaya/batteries/marine_ai')

  describe 'the live product path has ZERO references to Marine::Backend' do
    {
      'Agent::Runner' => root.join('app/services/marine/agent/runner.rb'),
      'Conversation::ResponseBuilderJob' => root.join('app/jobs/marine/conversation/response_builder_job.rb'),
      'Catalog::ProductQueryOrchestrator' => root.join('app/services/marine/catalog/product_query_orchestrator.rb')
    }.each do |label, path|
      it "#{label} does not reference Marine::Backend" do
        skip "missing #{path}" unless File.exist?(path)

        expect(File.read(path)).not_to include('Marine::Backend')
      end
    end
  end

  describe 'the only runtime consumers of Marine::Backend are the product-authority shadow + evaluator + acceptance coordinator' do
    it 'restricts every Marine::Backend reference to the backend services and the advisory product-authority files' do
      scan_dirs = [root.join('app/services/marine'), root.join('app/jobs/marine')]
      referencing = scan_dirs.flat_map { |dir| Dir[dir.join('**/*.rb').to_s] }
                             .select { |path| File.read(path).include?('Marine::Backend') }
                             .map { |path| Pathname.new(path).relative_path_from(root).to_s }

      allowed_product_authority = %w[
        app/services/marine/product_authority/shadow_execution.rb
        app/services/marine/product_authority/evaluator.rb
        app/services/marine/product_authority/acceptance_pipeline_coordinator.rb
        app/services/marine/product_authority/acceptance_case_result.rb
      ]

      # Phase 2A — the DEFAULT-OFF, read-only Decision shadow job is the single runtime consumer that
      # bridges the reused JEV CandidatePlan into Marine::Backend::AuthorityShadowExecution (no live
      # product path; inside the existing shadow gate).
      allowed_decision_bridge = %w[app/jobs/marine/decision/shadow_job.rb]

      referencing.each do |relative|
        permitted = relative.start_with?('app/services/marine/backend/') ||
                    allowed_product_authority.include?(relative) ||
                    allowed_decision_bridge.include?(relative)
        expect(permitted).to be(true), "unexpected Marine::Backend consumer: #{relative}"
      end

      # And the advisory consumers really are present in the set.
      expect(referencing).to include(*allowed_product_authority, *allowed_decision_bridge)
    end
  end

  describe 'the shadow enqueuer / job / execution perform no persistence' do
    persistence_tokens = ['.create!', '.update!', '.save!', 'with_lock'].freeze
    %w[
      app/services/marine/product_authority/shadow_enqueuer.rb
      app/jobs/marine/product_authority/shadow_job.rb
      app/services/marine/product_authority/shadow_execution.rb
    ].each do |relative|
      it "#{relative} makes no create!/update!/save!/with_lock call" do
        code = root.join(relative).read.gsub(/#(?!\{).*/, '')
        persistence_tokens.each { |token| expect(code).not_to include(token) }
      end
    end
  end

  describe 'ShadowExecution is adapter-only' do
    it 'never references the catalog-DB ProductExecutionPlanner' do
      source = root.join('app/services/marine/product_authority/shadow_execution.rb').read
      expect(source).not_to include('ProductExecutionPlanner')
    end
  end

  describe 'CandidateGate is phase-locked closed' do
    it 'declares PHASE_LOCKED = true in source' do
      source = root.join('app/services/marine/product_authority/candidate_gate.rb').read
      expect(source).to include('PHASE_LOCKED = true')
    end

    it 'never opens at runtime regardless of injected dependencies' do
      gate = Marine::ProductAuthority::CandidateGate.new(config: double, store: double, acceptance: double)
      expect(gate.open?(account_id: 1, assistant_id: 1)).to be(false)
    end
  end
end
