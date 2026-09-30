# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — proves the new Marine::Backend pipeline is ISOLATED: it
# calls no live provider / ERP / persistence, and NOTHING on the live product path (Agent::Runner,
# the ResponseBuilder jobs) references it. This is a static, deterministic source assertion.
RSpec.describe 'Marine::Backend Fase 3A-1 isolation' do
  root = Rails.root.join('custom/wijaya/batteries/marine_ai')
  backend_dir = root.join('app/services/marine/backend')

  backend_files = Dir[backend_dir.join('*.rb').to_s]

  it 'ships the expected backend services' do
    expect(backend_files.map { |path| File.basename(path) }).to include(
      'candidate_plan_to_product_intent_adapter.rb', 'product_execution_planner.rb',
      'product_state_transition.rb', 'evidence_packet_builder.rb',
      'evidence_packet_presenter.rb', 'evidence_prompt_builder.rb',
      'post_generation_fact_validator.rb', 'persona_validator.rb'
    )
  end

  # No live provider, ERP, persistence, InstallationConfig, migration, or live-path wiring.
  FORBIDDEN = {
    'live provider' => /Marine::Llm::BaseService|RubyLLM|\.chat\(|\.complete\(/,
    'ERP services' => /Frappe|ErpLead|LeadActivityService|ProductRequirementsService|OwnerSyncService|Wijaya::ErpSetting/,
    'persistence' => /\.create!|\.update!|\.save!|\.destroy!?\b|with_lock|ActiveRecord::Base/,
    'installation config' => /InstallationConfig/,
    'live product path' => /Marine::Agent::Runner|ResponseBuilderJob|ProductQueryOrchestrator/
  }.freeze

  backend_files.each do |path|
    relative = Pathname.new(path).relative_path_from(Rails.root)
    context File.basename(path) do
      source = File.read(path)

      FORBIDDEN.each do |label, pattern|
        it "makes no #{label} reference (#{relative})" do
          expect(source).not_to match(pattern)
        end
      end
    end
  end

  describe 'non-regression: live path has ZERO references to Marine::Backend' do
    {
      'Agent::Runner' => root.join('app/services/marine/agent/runner.rb'),
      'Conversation::ResponseBuilderJob' => root.join('app/jobs/marine/conversation/response_builder_job.rb')
    }.each do |label, path|
      it "#{label} does not reference Marine::Backend" do
        skip "missing #{path}" unless File.exist?(path)

        expect(File.read(path)).not_to include('Marine::Backend')
      end
    end
  end
end
