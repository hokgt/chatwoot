# frozen_string_literal: true

require 'rails_helper'

# Marine settings consumption contract.
#
# Executable freeze of which Chatwoot-visible Marine settings are ACTUALLY consumed at runtime,
# proved by exercising the REAL consumer (no reimplementation): for each runtime-consumed setting
# we set a SYNTHETIC value, call the real consumer method/service, and assert its OUTPUT/behavior
# reflects the change. Where a consumer would otherwise reach an external LLM/catalog, we stop at
# the built prompt / request / config boundary — never a network call.
#
# Every example names the traced consumer (file:line verified against the current tree) so the
# contract is self-documenting. Settings that are UI/API-editable but have NO runtime consumer
# (temperature, welcome_message, resolution_message, feature_faq, feature_contact_attributes) are
# intentionally NOT asserted here; they are reported as inert findings, not fixed this phase.
#
# Settings source shapes (verified):
#   * Marine::Assistant#config (jsonb) — store_accessor keys incl. instructions, handoff_message,
#     product_name, feature_memory, and 'language' (also read via config.to_h at some call sites).
#   * Marine::Assistant#guardrails / #response_guidelines — jsonb COLUMNS (not config keys).
#   * InstallationConfig MARINE_* keys — read through Marine::Llm::Config.installation_value.
#   * ENV MARINE_CATALOG_PG_* — read directly by Marine::Catalog::Config.
RSpec.describe 'Marine settings consumption contract' do
  # --- assistant.config['instructions'] + guardrails + response_guidelines ---------------------
  # Consumer: Marine::Charge::ResponseGenerator#rag_system_prompt (response_generator.rb:294-310)
  #           and #control_texts (response_generator.rb:286-292) — control-policy segment of the
  #           response LLM system prompt and the local leak-defense control text set.
  describe 'assistant instructions / guardrails / response_guidelines -> ResponseGenerator system prompt' do
    let(:account) { create(:account) }
    let(:assistant) do
      create(:marine_assistant, account: account,
                                config: { 'instructions' => 'SYNTH_INSTRUCTIONS stay in persona' },
                                guardrails: ['SYNTH_GUARDRAIL never promise refunds'],
                                response_guidelines: ['SYNTH_GUIDELINE answer briefly'])
    end
    let(:generator) { Marine::Charge::ResponseGenerator.new(assistant: assistant) }

    before do
      # Isolate the control-policy segment: the KB grounding collaborator is NOT the setting under
      # test, so stub it to nil (also avoids any retrieval/embedding side effect).
      allow(generator).to receive(:knowledge_base_context).and_return(nil)
    end

    it 'embeds the assistant instructions, guardrails and guidelines in the RAG system prompt' do
      prompt = generator.send(:rag_system_prompt)

      expect(prompt).to include('SYNTH_INSTRUCTIONS stay in persona')
      expect(prompt).to include("Guardrails:\n- SYNTH_GUARDRAIL never promise refunds")
      expect(prompt).to include("Response Guidelines:\n- SYNTH_GUIDELINE answer briefly")
    end

    it 'reflects an edited guardrail in the next built prompt (no caching of the stale value)' do
      assistant.update!(guardrails: ['SYNTH_GUARDRAIL_EDITED disclose nothing'])
      prompt = Marine::Charge::ResponseGenerator.new(assistant: assistant).tap do |g|
        allow(g).to receive(:knowledge_base_context).and_return(nil)
      end.send(:rag_system_prompt)

      expect(prompt).to include('SYNTH_GUARDRAIL_EDITED disclose nothing')
      expect(prompt).not_to include('never promise refunds')
    end

    it 'exposes all three as confidential control texts the leak guard protects' do
      texts = generator.send(:control_texts)

      expect(texts).to include('SYNTH_INSTRUCTIONS stay in persona')
      expect(texts).to include('SYNTH_GUARDRAIL never promise refunds')
      expect(texts).to include('SYNTH_GUIDELINE answer briefly')
    end
  end

  # --- assistant.config['language'] ------------------------------------------------------------
  # Consumer: Marine::Agent::Runner#configured_reply_language (agent/runner.rb:241-243) — last-resort
  # fallback supplied to the orchestrator language resolver. 'language' is a store_accessor key on
  # Marine::Assistant and is also read via config.to_h['language'] at some call sites.
  describe "assistant config['language'] -> Agent::Runner#configured_reply_language" do
    let(:account) { create(:account) }

    it 'returns the configured operating language' do
      assistant = create(:marine_assistant, account: account, config: { 'language' => 'id' })
      runner = Marine::Agent::Runner.new(assistant: assistant)

      expect(runner.send(:configured_reply_language)).to eq('id')
    end

    it 'is nil when unconfigured (resolver then falls back to turn/prior-customer language)' do
      assistant = create(:marine_assistant, account: account, config: {})
      runner = Marine::Agent::Runner.new(assistant: assistant)

      expect(runner.send(:configured_reply_language)).to be_nil
    end

    it 'exposes language as a config store_accessor (reads the persisted jsonb key)' do
      assistant = create(:marine_assistant, account: account, config: { 'language' => 'id' })

      expect(assistant.language).to eq('id')
    end

    it 'writes language through the store_accessor into the config jsonb' do
      assistant = create(:marine_assistant, account: account, config: {})
      assistant.update!(language: 'id')

      expect(assistant.reload.config['language']).to eq('id')
    end
  end

  # --- assistant.config['feature_memory'] ------------------------------------------------------
  # Consumer: Wijaya::Marine::Hooks#marine_memory_enabled? (hooks.rb:71-76) gates the
  # GenerateContactNotesJob enqueue; the job itself re-checks the same toggle
  # (generate_contact_notes_job.rb:17). Build a REAL assistant so the toggle is a real attribute.
  describe "assistant config['feature_memory'] -> Hooks memory-job gate" do
    let(:account) { create(:account) }
    let(:inbox) { double('inbox') }
    let(:conversation) { double('conversation', inbox: inbox, account: account) }

    it 'enqueues the contact-notes job when feature_memory is enabled' do
      assistant = create(:marine_assistant, account: account, config: { 'feature_memory' => true })
      allow(inbox).to receive(:marine_assistant).and_return(assistant)

      expect(Marine::Memory::GenerateContactNotesJob).to receive(:perform_later).with(conversation)
      Wijaya::Marine::Hooks.after_conversation_resolved(conversation)
    end

    it 'does not enqueue when feature_memory is unset' do
      assistant = create(:marine_assistant, account: account, config: {})
      allow(inbox).to receive(:marine_assistant).and_return(assistant)

      expect(Marine::Memory::GenerateContactNotesJob).not_to receive(:perform_later)
      Wijaya::Marine::Hooks.after_conversation_resolved(conversation)
    end
  end

  # --- assistant.config['handoff_message'] -----------------------------------------------------
  # Consumer: Marine::Circuit::HandoffService#create_handoff_message (handoff_service.rb:73-81) —
  # the public handoff line resolves to a per-turn message, else the configured handoff_message,
  # else DEFAULT_MESSAGE. Exercise the real resolution line via a capturing conversation double.
  describe "assistant config['handoff_message'] -> HandoffService public message" do
    let(:account) { create(:account) }

    def captured_handoff_content(assistant)
      content = nil
      messages = double('messages')
      allow(messages).to receive(:create!) do |attrs|
        content = attrs[:content]
        double('message', id: 1)
      end
      conversation = double('conversation', account_id: 1, inbox_id: 2, messages: messages)
      Marine::Circuit::HandoffService.new(conversation: conversation, assistant: assistant).send(:create_handoff_message)
      content
    end

    it 'uses the configured handoff_message as the public line' do
      assistant = create(:marine_assistant, account: account, config: { 'handoff_message' => 'SYNTH menghubungkan Anda ke agen.' })

      expect(captured_handoff_content(assistant)).to eq('SYNTH menghubungkan Anda ke agen.')
    end

    it 'falls back to DEFAULT_MESSAGE when no handoff_message is configured' do
      assistant = create(:marine_assistant, account: account, config: {})

      expect(captured_handoff_content(assistant)).to eq(Marine::Circuit::HandoffService::DEFAULT_MESSAGE)
    end
  end

  # --- assistant.config['product_name'] --------------------------------------------------------
  # Consumer: Marine::Copilot::BaseService#product_name (copilot/base_service.rb:73-76) — resolves
  # the assistant's product_name for the Copilot system prompt (query_service.rb:65,101-102 default
  # 'Marine AI'). marine_assistant is read via conversation.inbox.marine_assistant.
  describe "assistant config['product_name'] -> Copilot BaseService#product_name" do
    let(:account) { create(:account) }

    def resolved_product_name(assistant)
      inbox = double('inbox', marine_assistant: assistant)
      conversation = double('conversation', inbox: inbox)
      Marine::Copilot::BaseService.new(account: account, conversation: conversation).send(:product_name)
    end

    it 'resolves the configured product name' do
      assistant = create(:marine_assistant, account: account, config: { 'product_name' => 'SYNTH Kain Nusantara' })

      expect(resolved_product_name(assistant)).to eq('SYNTH Kain Nusantara')
    end

    it 'is nil when unconfigured (the Copilot prompt then applies its own default)' do
      assistant = create(:marine_assistant, account: account, config: {})

      expect(resolved_product_name(assistant)).to be_nil
    end
  end

  # --- MARINE_LLM_PROVIDER / MARINE_OPEN_AI_* + MARINE_DECISION_LLM_* ---------------------------
  # Consumer: Marine::Llm::SettingsStore (settings_store.rb) over Marine::Llm::Config /
  # Marine::Llm::ProviderConfig — the response_generator target IS the live runtime LLM config; the
  # decision_maker target reads its own MARINE_DECISION_LLM_* keys, each falling back to the
  # response value. InstallationConfig.find_by is stubbed with synthetic values (established idiom).
  describe 'LLM settings-store target keys -> resolved provider/model/endpoint' do
    def stub_config(name, value)
      allow(InstallationConfig).to receive(:find_by).with(name: name)
                                                    .and_return(instance_double(InstallationConfig, value: value))
    end

    before do
      allow(InstallationConfig).to receive(:find_by).and_return(nil)
    end

    it 'resolves the response_generator (live runtime) config from the MARINE_OPEN_AI_* keys' do
      stub_config('MARINE_LLM_PROVIDER', 'gemini')
      stub_config('MARINE_OPEN_AI_MODEL', 'synth-model')
      stub_config('MARINE_OPEN_AI_ENDPOINT', 'https://synth.endpoint')

      store = Marine::Llm::SettingsStore.for(:response_generator)
      expect(store.provider).to eq('gemini')
      expect(store.model).to eq('synth-model')
      expect(store.endpoint).to eq('https://synth.endpoint')
    end

    it 'resolves the decision_maker config from its own MARINE_DECISION_LLM_* keys' do
      stub_config('MARINE_DECISION_LLM_PROVIDER', 'openrouter')
      stub_config('MARINE_DECISION_LLM_MODEL', 'synth-decision-model')
      stub_config('MARINE_DECISION_LLM_ENDPOINT', 'https://synth.decision')

      store = Marine::Llm::SettingsStore.for(:decision_maker)
      expect(store.provider).to eq('openrouter')
      expect(store.model).to eq('synth-decision-model')
      expect(store.endpoint).to eq('https://synth.decision')
    end

    it 'falls the decision_maker back to the response_generator value when its own key is unset' do
      stub_config('MARINE_OPEN_AI_MODEL', 'synth-shared-model')

      expect(Marine::Llm::SettingsStore.for(:decision_maker).model).to eq('synth-shared-model')
    end
  end

  # --- MARINE_DECISION_CUTOVER_ENABLED / ROLLBACK / ASSISTANT_IDS ------------------------------
  # Consumer/reader: Marine::Decision::CutoverConfig (cutover_config.rb:53-89) — the fail-closed
  # scenario-selection cutover reader. We spec ONLY the reader seam (enabled?/rollback?/allowlist)
  # with synthetic InstallationConfig values; we do NOT enable the cutover or touch ShadowConfig.
  describe 'MARINE_DECISION_CUTOVER_* -> CutoverConfig reader seam' do
    def stub_config(name, value)
      allow(InstallationConfig).to receive(:find_by).with(name: name)
                                                    .and_return(instance_double(InstallationConfig, value: value))
    end

    before do
      allow(InstallationConfig).to receive(:find_by).and_return(nil)
    end

    it 'reads the enabled flag only for the exact trimmed "true"' do
      stub_config('MARINE_DECISION_CUTOVER_ENABLED', 'true')
      expect(Marine::Decision::CutoverConfig.enabled?).to be(true)

      stub_config('MARINE_DECISION_CUTOVER_ENABLED', 'TRUE')
      expect(Marine::Decision::CutoverConfig.enabled?).to be(false)
    end

    it 'reads the rollback kill switch from MARINE_DECISION_CUTOVER_ROLLBACK' do
      stub_config('MARINE_DECISION_CUTOVER_ROLLBACK', 'true')
      expect(Marine::Decision::CutoverConfig.rollback?).to be(true)
    end

    it 'parses the assistant allowlist JSON and fails the whole list closed on an anomaly' do
      stub_config('MARINE_DECISION_CUTOVER_ASSISTANT_IDS', '[3, 7]')
      expect(Marine::Decision::CutoverConfig.assistant_allowlist).to eq([3, 7])

      stub_config('MARINE_DECISION_CUTOVER_ASSISTANT_IDS', '[3, "7"]')
      expect(Marine::Decision::CutoverConfig.assistant_allowlist).to eq([])
    end
  end

  # --- MARINE_CATALOG_PG_* ---------------------------------------------------------------------
  # Consumer/reader: Marine::Catalog::Config (catalog/config.rb:29-55) — server-only, READ-ONLY
  # catalog connection. Non-secret details come from ENV; the password is read from a secret file.
  # Spec the reader seam with synthetic ENV + a Tempfile secret; never connects.
  describe 'MARINE_CATALOG_PG_* -> Catalog::Config reader seam' do
    it 'resolves the non-secret connection details from ENV (with validated identifiers)' do
      with_modified_env MARINE_CATALOG_PG_HOST: 'synth-db.internal', MARINE_CATALOG_PG_PORT: '6543',
                        MARINE_CATALOG_PG_DATABASE: 'synth_catalog', MARINE_CATALOG_PG_USER: 'synth_reader',
                        MARINE_CATALOG_PG_SCHEMA: 'synth_schema', MARINE_CATALOG_PG_TABLE: 'synth_item' do
        expect(Marine::Catalog::Config.host).to eq('synth-db.internal')
        expect(Marine::Catalog::Config.port).to eq(6543)
        expect(Marine::Catalog::Config.database).to eq('synth_catalog')
        expect(Marine::Catalog::Config.user).to eq('synth_reader')
        expect(Marine::Catalog::Config.qualified_table).to eq('synth_schema.synth_item')
      end
    end

    it 'reads the login credential from the secret file and reports configured? only when complete' do
      Tempfile.create('synth_catalog_secret') do |file|
        file.write("synth-catalog-password\n")
        file.flush

        with_modified_env MARINE_CATALOG_PG_HOST: 'synth-db.internal', MARINE_CATALOG_PG_DATABASE: 'synth_catalog',
                          MARINE_CATALOG_PG_USER: 'synth_reader', MARINE_CATALOG_PG_PASSWORD_FILE: file.path do
          expect(Marine::Catalog::Config.password).to eq('synth-catalog-password')
          expect(Marine::Catalog::Config.configured?).to be(true)
        end
      end
    end

    it 'is not configured when the password file is absent' do
      with_modified_env MARINE_CATALOG_PG_HOST: 'synth-db.internal', MARINE_CATALOG_PG_DATABASE: 'synth_catalog',
                        MARINE_CATALOG_PG_USER: 'synth_reader', MARINE_CATALOG_PG_PASSWORD_FILE: nil do
        expect(Marine::Catalog::Config.configured?).to be(false)
      end
    end
  end
end
