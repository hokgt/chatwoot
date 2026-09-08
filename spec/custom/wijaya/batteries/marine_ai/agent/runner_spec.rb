# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Agent::Runner do
  let(:assistant) { double('assistant', id: 1, name: 'Marine Bot', account: nil) }
  let(:generator) { instance_double(Marine::Charge::ResponseGenerator) }
  let(:selector) { instance_double(Marine::Agent::ScenarioSelector) }
  let(:runner) { described_class.new(assistant: assistant) }

  def reply_payload(overrides = {})
    {
      'response' => 'Your order is on the way',
      'action' => 'reply',
      'agent_name' => 'Marine Bot',
      'marine_cell_response_id' => 9,
      'confidence' => 0.9,
      'citations' => [{ response_id: 9, question: 'Where is my order', source_type: 'manual' }],
      'source_type' => 'manual',
      'response_ids' => [9],
      'document_ids' => [],
      'fallback_reason' => nil,
      'detected_language' => 'en',
      'translation_applied' => false
    }.merge(overrides)
  end

  def handoff_payload(overrides = {})
    {
      'response' => 'conversation_handoff',
      'action' => 'handoff',
      'action_source' => 'marine_circuit',
      'action_reason' => 'no_confident_cell_match',
      'detected_language' => 'en',
      'translation_applied' => false
    }.merge(overrides)
  end

  before do
    allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
    allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(selector)
    allow(selector).to receive(:select).and_return(nil)
    # These examples exercise the runner's routing / greeting / Playground behavior, NOT the shared
    # domain-boundary seam (which is covered in full by runner_domain_boundary_spec and
    # domain_boundary_guard_spec). The guard is now fail-CLOSED on an unconfigured LLM, so stub it to
    # ALLOW here — the production "allowed, in-domain" decision — so every non-boundary case continues
    # to fall through to the RAG ResponseGenerator exactly as before.
    allow(Marine::Circuit::DomainBoundaryGuard).to receive(:new).and_return(
      instance_double(Marine::Circuit::DomainBoundaryGuard, call: nil)
    )
  end

  describe 'default retrieval path' do
    it 'returns the retrieval reply enriched with orchestration metadata' do
      allow(generator).to receive(:generate).and_return(reply_payload)

      payload = runner.run(additional_message: 'Where is my order')

      expect(payload).to include(
        'response' => 'Your order is on the way',
        'action' => 'reply',
        'confidence' => 0.9,
        'source_type' => 'manual',
        'orchestration_path' => 'retrieval',
        'marine_scenario_id' => nil,
        'marine_scenario_tools' => []
      )
      expect(payload['citations']).to be_an(Array)
    end
  end

  describe 'scenario selection path' do
    let(:scenario) { double('scenario', id: 7, title: 'Order status', resolved_tools: []) }

    it 'marks the path as scenario_retrieval when a scenario matches' do
      allow(selector).to receive(:select).with('Where is my order').and_return(scenario)
      allow(generator).to receive(:generate).and_return(reply_payload)

      payload = runner.run(additional_message: 'Where is my order')

      expect(payload).to include(
        'orchestration_path' => 'scenario_retrieval',
        'marine_scenario_id' => 7,
        'marine_scenario_title' => 'Order status',
        'marine_scenario_tools' => []
      )
    end
  end

  # Custom HTTP tools have been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP; the runner never resolves tool slugs
  # and marine_scenario_tools stays an empty array.
  describe 'tool reference resolution path (disabled)' do
    let(:account) { create(:account) }
    let(:db_assistant) { create(:marine_assistant, account: account) }
    let(:runner) { described_class.new(assistant: db_assistant) }

    before do
      allow(Marine::Agent::ScenarioSelector).to receive(:new).and_call_original
      allow(generator).to receive(:generate).and_return(reply_payload)
    end

    it 'never resolves tool slugs and exposes no auth secrets' do
      create(:marine_custom_tool, account: account, slug: 'custom_fetch-order', title: 'Fetch Order',
                                  description: 'Gets order details', auth_type: 'bearer',
                                  auth_config: { 'token' => 'super-secret-token' })
      create(:marine_scenario, assistant: db_assistant, account: account,
                               title: 'Order status', description: 'Track a delivery order shipment',
                               instruction: 'Track the order shipment using [@Fetch Order](tool://custom_fetch-order)')

      payload = runner.run(additional_message: 'track my order shipment delivery')

      expect(payload['marine_scenario_tools']).to eq([])
      expect(payload.to_s).not_to include('super-secret-token')
      expect(payload.to_s).not_to include('auth_config')
    end
  end

  describe 'multilingual fallback behavior' do
    it 'preserves translation metadata produced by the retrieval generator' do
      allow(generator).to receive(:generate).and_return(
        reply_payload('detected_language' => 'id', 'query_language' => 'id',
                      'translation_applied' => true, 'response_translation_applied' => true)
      )

      payload = runner.run(additional_message: 'Pesanan saya di mana')

      expect(payload).to include(
        'detected_language' => 'id',
        'query_language' => 'id',
        'translation_applied' => true,
        'response_translation_applied' => true,
        'orchestration_path' => 'retrieval'
      )
    end
  end

  describe 'low confidence / no result handoff path' do
    it 'returns the handoff payload with the retrieval fallback reason' do
      allow(generator).to receive(:generate).and_return(handoff_payload)

      payload = runner.run(additional_message: 'unknown question')

      expect(payload).to include(
        'response' => 'conversation_handoff',
        'action' => 'handoff',
        'action_reason' => 'no_confident_cell_match',
        'orchestration_path' => 'handoff'
      )
    end
  end

  describe 'safety when orchestration fails' do
    it 'never raises and degrades to a handoff payload with a runner_error reason' do
      allow(generator).to receive(:generate).and_raise(StandardError, 'boom')

      payload = runner.run(additional_message: 'Where is my order')

      expect(payload).to include(
        'response' => 'conversation_handoff',
        'action' => 'handoff',
        'action_reason' => 'runner_error',
        'orchestration_path' => 'handoff'
      )
    end
  end

  describe 'product path (Phase 5)' do
    let(:account) { build_stubbed(:account) }
    let(:conversation) { build_stubbed(:conversation, account: account) }
    let(:message) { build_stubbed(:message, conversation: conversation, message_type: :incoming, content: 'price for impeller 3 inch') }
    let(:runner) { described_class.new(assistant: assistant, conversation: conversation, source: message) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }

    before do
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
      # Gate G — the runner consults deterministic retrieval before product orchestration; the
      # assistant double has no KB, so return a no-match result (no exact-FAQ precedence) and let
      # the product path run exactly as before.
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match'))
      )
    end

    it 'runs the orchestrator before RAG and returns the product plan payload' do
      plan = { action: :reply, reply: { kind: :price_available }, state: { operation: :update, changes: {} } }
      allow(orchestrator).to receive(:process).and_return(plan)
      allow(generator).to receive(:generate)

      payload = runner.run(additional_message: 'price for impeller 3 inch')

      expect(payload).to eq('action' => 'product', 'orchestration_path' => 'product', 'product_plan' => plan)
      expect(generator).not_to have_received(:generate)
    end

    it 'passes the exact incoming message content and the current flow snapshot to the orchestrator' do
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)

      runner.run(additional_message: 'ignored — text comes from the trigger message')

      expect(orchestrator).to have_received(:process).with(hash_including(text: 'price for impeller 3 inch', suppressed: false))
    end

    it 'falls through to the unchanged retrieval path on a not_product plan' do
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)

      payload = runner.run(additional_message: 'just saying hello')

      expect(payload).to include('response' => 'Your order is on the way', 'orchestration_path' => 'retrieval')
    end
  end

  # Phase 2 — the trigger-bound runner derives canonical prior history + a separately bounded
  # current trigger from the real Conversation, and feeds the SAME history and the trigger
  # (once) to both the product-intent path and the RAG path. Uses persisted records so the
  # canonical ContextBuilder query runs for real.
  describe 'canonical conversation context integration (Phase 2)' do
    let(:account) { create(:account) }
    let(:marine) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:base) { Time.zone.parse('2026-06-01 09:00:00') }
    let(:runner) { described_class.new(assistant: marine, conversation: conversation, source: trigger) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }

    let!(:prior_incoming) do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :incoming, content: 'earlier customer question', created_at: base + 1)
    end
    let!(:prior_marine) do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :outgoing, sender: marine, content: 'earlier marine answer', created_at: base + 2)
    end
    let!(:trigger) do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :incoming, content: 'current customer turn', created_at: base + 10)
    end
    let(:canonical_history) do
      [{ role: 'user', content: 'earlier customer question' },
       { role: 'assistant', content: 'earlier marine answer' }]
    end

    before do
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)
    end

    it 'gives the product IntentExtractor path the canonical prior history and the separate trigger (never duplicated in context)' do
      runner.run

      expect(orchestrator).to have_received(:process).with(
        hash_including(text: 'current customer turn', context: canonical_history, suppressed: false)
      )
    end

    it 'gives the RAG ResponseGenerator the same canonical history and the separate trigger' do
      runner.run

      # A prior public Marine reply exists (prior_marine), so this is a follow-up turn and the
      # opening/greeting signal threaded to the generator is false (Phase 4).
      expect(generator).to have_received(:generate).with(
        additional_message: 'current customer turn', message_history: canonical_history, opening: false
      )
    end
  end

  # Phase 4 — the runner threads the canonical opening/follow-up signal to the RAG generator so
  # the greeting is gated by whether Marine has already replied publicly in this conversation.
  describe 'opening/follow-up greeting signal wiring (Phase 4)' do
    let(:account) { create(:account) }
    let(:marine) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:base) { Time.zone.parse('2026-06-01 09:00:00') }
    let(:runner) { described_class.new(assistant: marine, conversation: conversation, source: trigger) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }

    before do
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)
    end

    context 'when no earlier public Marine reply exists (opening turn)' do
      let!(:trigger) do
        create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                         message_type: :incoming, content: 'first customer turn', created_at: base + 10)
      end

      it 'threads opening: true to the generator' do
        runner.run
        expect(generator).to have_received(:generate).with(hash_including(opening: true))
      end
    end

    context 'when an earlier public Marine reply exists (follow-up turn)' do
      let!(:prior_marine) do
        create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                         message_type: :outgoing, sender: marine, content: 'earlier marine answer', created_at: base + 2)
      end
      let!(:trigger) do
        create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                         message_type: :incoming, content: 'follow-up turn', created_at: base + 10)
      end

      it 'threads opening: false to the generator' do
        runner.run
        expect(generator).to have_received(:generate).with(hash_including(opening: false))
      end
    end
  end

  # Finding 1 — a source-less run (no bound trigger Message: the legacy ResponseBuilderJob path
  # or any direct source-less caller) has no ContextBuilder result, but still obeys the exact
  # opening rule. With no trigger boundary the phase is derived straight from the Conversation:
  # opening ONLY until any public Marine reply exists, follow-up forever after. Product Flow
  # stays disabled on this path (no source), so only the greeting signal changes.
  describe 'source-less conversation greeting phase (Finding 1)' do
    let(:account) { create(:account) }
    let(:marine) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:runner) { described_class.new(assistant: marine, conversation: conversation) }

    before do
      allow(generator).to receive(:generate).and_return(reply_payload)
    end

    def marine_reply(**attrs)
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :outgoing, sender: marine, **attrs)
    end

    it 'threads opening: false when a prior public Marine reply exists' do
      marine_reply(content: 'earlier marine answer')

      runner.run(additional_message: 'another question')

      expect(generator).to have_received(:generate).with(hash_including(opening: false))
    end

    it 'threads opening: true when no prior public Marine reply exists' do
      runner.run(additional_message: 'first customer turn')

      expect(generator).to have_received(:generate).with(hash_including(opening: true))
    end

    it 'stays opening when only a private Marine note or a human User public reply exists' do
      marine_reply(content: 'internal note', private: true)
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :outgoing, sender: agent, content: 'human agent reply')

      runner.run(additional_message: 'still the first customer turn')

      expect(generator).to have_received(:generate).with(hash_including(opening: true))
    end

    it 'never re-enables opening after a public Marine reply despite resolve/reopen/inactivity' do
      marine_reply(content: 'earlier marine answer', created_at: 90.days.ago)
      conversation.update!(status: :resolved)
      conversation.update!(status: :open)

      runner.run(additional_message: 'much later customer turn')

      expect(generator).to have_received(:generate).with(hash_including(opening: false))
    end
  end

  # Phase 3 — the runner supplies the EFFECTIVE planning snapshot (current_for_planning), so an
  # active flow whose TTL has elapsed reaches the orchestrator as expired and is never reused.
  describe 'effective expiry snapshot (Phase 3)' do
    let(:account) { create(:account) }
    let(:marine) { create(:marine_assistant, account: account) }
    let(:conversation) { create(:conversation, account: account) }
    let(:trigger) do
      create(:message, conversation: conversation, account: account, inbox: conversation.inbox,
                       message_type: :incoming, content: 'price please')
    end
    let(:runner) { described_class.new(assistant: marine, conversation: conversation, source: trigger) }
    let(:orchestrator) { instance_double(Marine::Catalog::ProductQueryOrchestrator) }

    before do
      allow(Marine::Catalog::ProductQueryOrchestrator).to receive(:new).and_return(orchestrator)
      allow(orchestrator).to receive(:process).and_return(action: :not_product, reply: nil, state: { operation: :none, changes: {} })
      allow(generator).to receive(:generate).and_return(reply_payload)
      # A valid, active flow whose expiry is already in the past (validated family + catalog markers).
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => {
                             'version' => 3, 'flow_id' => 'stale', 'status' => 'active', 'expires_at' => 1.year.ago.iso8601,
                             'validated_family' => 'FAM-OLD', 'catalog_sent' => true, 'clarification_count' => 2, 'clarification_kind' => 'variant'
                           } } })
    end

    it 'passes the orchestrator an expired snapshot (never the active status) so nothing elapsed is reused' do
      runner.run

      expect(orchestrator).to have_received(:process).with(
        hash_including(flow: hash_including('status' => 'expired', 'validated_family' => 'FAM-OLD'))
      )
    end

    it 'does not persist the expiry transition during reasoning (the DB row stays active until finalization)' do
      runner.run

      persisted = conversation.reload.additional_attributes['wijaya_marine_ai']['product_flow_v1']
      expect(persisted['status']).to eq('active')
      expect(persisted['version']).to eq(3)
    end
  end

  # Playground / direct source-less run with NO conversation to inspect: the caller-supplied
  # message_history is the only interaction-phase signal, so the multi-turn preview grounds on the
  # prior turns and the greeting is gated by whether an assistant turn already exists in history.
  describe 'nil-conversation source-less run derives greeting phase from message_history' do
    let(:runner) { described_class.new(assistant: assistant, source: 'playground') }

    before do
      allow(generator).to receive(:generate).and_return(reply_payload)
      # Gate G on the playground path retrieves; no exact FAQ match here, so it falls through.
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match'))
      )
    end

    it 'forwards the supplied history and threads opening: true when no assistant turn exists yet' do
      history = [{ role: 'user', content: 'first turn' }]

      runner.run(additional_message: 'first turn', message_history: history)

      expect(generator).to have_received(:generate).with(
        hash_including(message_history: history, opening: true)
      )
    end

    it 'threads opening: false once a prior assistant turn exists in the supplied history' do
      history = [{ role: 'user', content: 'earlier' }, { role: 'assistant', content: 'earlier reply' }]

      runner.run(additional_message: 'follow up', message_history: history)

      expect(generator).to have_received(:generate).with(
        hash_including(message_history: history, opening: false)
      )
    end

    it 'keeps the legacy opening default (true) when no history is supplied' do
      runner.run(additional_message: 'only turn')

      expect(generator).to have_received(:generate).with(hash_including(opening: true))
    end
  end

  # Source-less Playground catalog preview: a run with NO conversation but a product account
  # previews the SAME product orchestration a real turn uses, so a valid catalog request is
  # grounded in the catalog BEFORE the RAG path (which would otherwise answer "unavailable").
  describe 'source-less Playground catalog preview' do
    let(:account) { instance_double(Account) }
    let(:assistant) { double('assistant', id: 1, name: 'Marine Bot', account: account) }
    let(:runner) { described_class.new(assistant: assistant, source: 'playground') }
    let(:preview) { instance_double(Marine::Catalog::PlaygroundPreview) }

    before do
      allow(Marine::Catalog::PlaygroundPreview).to receive(:new).and_return(preview)
      # No exact approved FAQ, so Gate G lets the turn reach the catalog preview.
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match'))
      )
    end

    it 'returns the preview payload and skips RAG for a product/catalog turn' do
      payload = { 'response' => 'The Baby Doll catalog is available and would be shared with the customer in a full conversation.',
                  'action' => 'reply', 'source_type' => 'marine_product', 'orchestration_path' => 'product' }
      allow(preview).to receive(:call).and_return(payload)
      allow(generator).to receive(:generate).and_return(reply_payload)

      result = runner.run(additional_message: 'ada katalog baby doll ?', message_history: [])

      expect(result).to eq(payload)
      expect(Marine::Catalog::PlaygroundPreview).to have_received(:new).with(assistant: assistant, account: account)
      expect(preview).to have_received(:call).with(query: 'ada katalog baby doll ?', history: [], state_token: nil, knowledge_available: false)
      expect(generator).not_to have_received(:generate)
    end

    it 'forwards the ephemeral signed state token to the preview' do
      runner = described_class.new(assistant: assistant, source: 'playground', state_token: 'signed-prior')
      allow(preview).to receive(:call).and_return('response' => 'ok', 'action' => 'reply')

      runner.run(additional_message: 'ada katalog baby doll ?', message_history: [])

      expect(preview).to have_received(:call).with(hash_including(state_token: 'signed-prior'))
    end

    it 'falls through to the unchanged RAG path when the preview declines (non-product)' do
      allow(preview).to receive(:call).and_return(nil)
      allow(generator).to receive(:generate).and_return(reply_payload)

      result = runner.run(additional_message: 'selamat pagi', message_history: [])

      expect(result).to include('orchestration_path' => 'retrieval')
      expect(generator).to have_received(:generate)
    end

    it 'bypasses the catalog preview when an EXACT approved FAQ matches (Gate G on the playground path)' do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.new(
                          responses: [], confidence: Marine::Charge::ConfidenceScorer::EXACT_MATCH_SCORE,
                          fallback_reason: nil
                        ))
      )
      allow(generator).to receive(:generate).and_return(reply_payload('response' => 'FAQ answer'))

      result = runner.run(additional_message: 'ada katalog baby doll ?', message_history: [])

      expect(Marine::Catalog::PlaygroundPreview).not_to have_received(:new)
      expect(result).to include('orchestration_path' => 'retrieval')
      expect(generator).to have_received(:generate)
    end
  end

  # A Playground turn that falls through to RAG/FAQ/non-product carries no fresh state_token, so
  # the browser would clear the signed flow. The runner re-verifies the incoming token and echoes
  # the SAME valid signed string verbatim (no re-encode, no TTL extension) so the ephemeral flow
  # survives a non-product turn — while a tampered/expired/foreign token is never echoed.
  describe 'Playground ephemeral state preservation across RAG/FAQ/non-product turns' do
    let(:account) { instance_double(Account, id: 55) }
    let(:assistant) { double('assistant', id: 1, name: 'Marine Bot', account: account) }
    let(:preview) { instance_double(Marine::Catalog::PlaygroundPreview) }
    let(:snapshot) do
      { 'version' => 1, 'flow_id' => 'f', 'status' => 'active',
        'expires_at' => 1.hour.from_now.iso8601, 'validated_family' => 'BD' }
    end
    let(:valid_token) { Marine::Catalog::PlaygroundStateToken.new(account: account, assistant: assistant).encode(snapshot) }

    def playground_runner(token)
      described_class.new(assistant: assistant, source: 'playground', state_token: token)
    end

    before do
      allow(Marine::Catalog::PlaygroundPreview).to receive(:new).and_return(preview)
      allow(preview).to receive(:call).and_return(nil) # non-product: preview declines, falls to RAG
      allow(generator).to receive(:generate).and_return(reply_payload)
    end

    it 'echoes the SAME valid signed token unchanged on a non-product RAG reply' do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match'))
      )

      result = playground_runner(valid_token).run(additional_message: 'selamat pagi', message_history: [])

      expect(result['orchestration_path']).to eq('retrieval')
      expect(result['state_token']).to eq(valid_token)
    end

    it 'echoes the SAME valid signed token on an EXACT approved FAQ reply (Gate G fall-through)' do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.new(
                          responses: [], confidence: Marine::Charge::ConfidenceScorer::EXACT_MATCH_SCORE, fallback_reason: nil
                        ))
      )
      allow(generator).to receive(:generate).and_return(reply_payload('response' => 'FAQ answer'))

      result = playground_runner(valid_token).run(additional_message: 'jam buka?', message_history: [])

      expect(Marine::Catalog::PlaygroundPreview).not_to have_received(:new)
      expect(result['state_token']).to eq(valid_token)
    end

    it 'never echoes a tampered token' do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'x'))
      )

      result = playground_runner("#{valid_token}tampered").run(additional_message: 'selamat pagi', message_history: [])

      expect(result).not_to have_key('state_token')
    end

    it 'never echoes an expired token' do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'x'))
      )
      token = valid_token

      result = travel_to((Marine::Catalog::PlaygroundStateToken::TTL_SECONDS + 60).seconds.from_now) do
        playground_runner(token).run(additional_message: 'selamat pagi', message_history: [])
      end

      expect(result).not_to have_key('state_token')
    end

    it 'never echoes a foreign token minted for a different assistant/account scope' do
      foreign_account = instance_double(Account, id: 999)
      foreign_assistant = double('assistant', id: 42, name: 'Other', account: foreign_account)
      foreign_token = Marine::Catalog::PlaygroundStateToken.new(account: foreign_account, assistant: foreign_assistant).encode(snapshot)
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'x'))
      )

      result = playground_runner(foreign_token).run(additional_message: 'selamat pagi', message_history: [])

      expect(result).not_to have_key('state_token')
    end

    it 'echoes no token when the browser cleared it on reset/switch (nil token)' do
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'x'))
      )

      result = playground_runner(nil).run(additional_message: 'selamat pagi', message_history: [])

      expect(result).not_to have_key('state_token')
    end

    it 'does not echo a token for a non-Playground caller even when a valid token is present' do
      conversation_account = account
      db_assistant = double('assistant', id: 1, name: 'Marine Bot', account: conversation_account)
      runner = described_class.new(assistant: db_assistant, source: nil, state_token: valid_token)
      allow(generator).to receive(:generate).and_return(reply_payload)

      result = runner.run(additional_message: 'where is my order')

      expect(result).not_to have_key('state_token')
    end
  end

  describe 'source-less run gating' do
    it 'never previews for a non-playground source-less caller even with a product account (source gate)' do
      account = instance_double(Account)
      assistant = double('assistant', id: 1, name: 'Marine Bot', account: account)
      runner = described_class.new(assistant: assistant, source: nil)
      allow(generator).to receive(:generate).and_return(reply_payload)
      expect(Marine::Catalog::PlaygroundPreview).not_to receive(:new)

      runner.run(additional_message: 'ada katalog baby doll ?')

      expect(generator).to have_received(:generate)
    end

    it 'skips the preview entirely when the assistant has no product account and uses RAG' do
      runner = described_class.new(assistant: assistant, source: 'playground')
      allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
        instance_double(Marine::Cell::KnowledgeBaseService,
                        retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'x'))
      )
      allow(generator).to receive(:generate).and_return(reply_payload)
      expect(Marine::Catalog::PlaygroundPreview).not_to receive(:new)

      runner.run(additional_message: 'ada katalog baby doll ?')

      expect(generator).to have_received(:generate)
    end
  end

  describe 'independence from Captain premium gates' do
    it 'does not reference any Captain runtime dependency in the source' do
      source = File.read(Rails.root.join('custom/wijaya/batteries/marine_ai/app/services/marine/agent/runner.rb'))
      captain_dependency = Regexp.union('Captain::', 'ChatwootHub', 'hub.2.chatwoot.com', 'pricing_plan',
                                        'CAPTAIN_CLOUD_PLAN_LIMITS', 'FEATURE_FLAGS.CAPTAIN', 'captain_integration')
      expect(source).not_to match(captain_dependency)
    end
  end
end
