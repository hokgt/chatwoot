# frozen_string_literal: true

require 'rails_helper'

# Marine::Backend isolation — proves the backend pipeline stays off every live/raw path. Two
# categories live under the backend dir and are held to DIFFERENT (but equally strict) contracts:
#
#   * Fase 3A-1 (isolated / mock-only) services — call no live provider / ERP / persistence /
#     InstallationConfig and make NO live-product-path reference at all (not even in a comment).
#   * Phase 2A (PRICE-ONLY read-only shadow bridge) — the catalog resolver, family price-range
#     authority, coordinator, and shadow execution. These are DELIBERATELY wired read-only (they
#     read ContextBuilder / ProductFlowStateStore#current_for_planning / ShadowConfig and are
#     grounded, in their comments, on the exact ProductQueryOrchestrator / legacy-Runner semantics),
#     so they still forbid any live provider, ERP, WRITE, direct InstallationConfig read, a SECOND
#     Decision provider/Runner, and any live-path WIRING (instantiation / job enqueue).
#
# Either way NOTHING on the live product path (Agent::Runner, the ResponseBuilder jobs) references
# Marine::Backend. This is a static, deterministic source assertion.
RSpec.describe 'Marine::Backend isolation' do
  root = Rails.root.join('custom/wijaya/batteries/marine_ai')
  backend_dir = root.join('app/services/marine/backend')

  backend_files = Dir[backend_dir.join('*.rb').to_s]

  # The Phase 2A read-only shadow-bridge files, held to the wired-but-read-only contract below; every
  # other backend file is a mock-only Fase 3A-1 service held to the strict isolated contract.
  PHASE_2A_FILES = %w[
    catalog_candidate_resolver.rb family_price_range_authority.rb
    authority_coordinator.rb authority_shadow_execution.rb
  ].freeze

  it 'ships the expected backend services' do
    expect(backend_files.map { |path| File.basename(path) }).to include(
      'candidate_plan_to_product_intent_adapter.rb', 'product_execution_planner.rb',
      'product_state_transition.rb', 'evidence_packet_builder.rb',
      'evidence_packet_presenter.rb', 'evidence_prompt_builder.rb',
      'post_generation_fact_validator.rb', 'persona_validator.rb', *PHASE_2A_FILES
    )
  end

  # Fase 3A-1 (isolated / mock-only): no live provider, ERP, persistence, InstallationConfig, or any
  # live-product-path reference (comment references are forbidden too for these pure files).
  FORBIDDEN = {
    'live provider' => /Marine::Llm::BaseService|RubyLLM|\.chat\(|\.complete\(/,
    'ERP services' => /Frappe|ErpLead|LeadActivityService|ProductRequirementsService|OwnerSyncService|Wijaya::ErpSetting/,
    'persistence' => /\.create!|\.update!|\.save!|\.destroy!?\b|with_lock|ActiveRecord::Base/,
    'installation config' => /InstallationConfig/,
    'live product path' => /Marine::Agent::Runner|ResponseBuilderJob|ProductQueryOrchestrator/
  }.freeze

  # Phase 2A (read-only shadow bridge): no live provider, ERP, WRITE, direct InstallationConfig read,
  # SECOND Decision provider/Runner, or live-path WIRING (instantiation / job). Read-only references
  # to ContextBuilder / ProductFlowStateStore / ShadowConfig and comment grounding are allowed.
  PHASE_2A_FORBIDDEN = {
    'live provider' => /Marine::Llm::BaseService|RubyLLM|\.chat\(|\.complete\(/,
    'ERP services' => /Frappe|ErpLead|LeadActivityService|ProductRequirementsService|OwnerSyncService|Wijaya::ErpSetting/,
    'persistence (write)' => /\.create!|\.update!|\.save!|\.destroy!?\b|with_lock|ActiveRecord::Base/,
    'direct installation config' => /InstallationConfig/,
    'second decision provider/runner' =>
      /Marine::Decision::Runner\.new|Marine::Decision::ScenarioAdapter\.new|Marine::Decision::ShadowExecution\.new/,
    'live product path wiring' => /Marine::Agent::Runner\.new|ResponseBuilderJob|Marine::Catalog::ProductQueryOrchestrator\.new/
  }.freeze

  backend_files.each do |path|
    relative = Pathname.new(path).relative_path_from(Rails.root)
    basename = File.basename(path)
    forbidden = PHASE_2A_FILES.include?(basename) ? PHASE_2A_FORBIDDEN : FORBIDDEN

    context basename do
      source = File.read(path)

      forbidden.each do |label, pattern|
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
