# frozen_string_literal: true

require 'rails_helper'

# ACCEPTANCE — the latest four-turn Playground reproduction, driven through the REAL controller,
# AssistantChatService, Agent::Runner (source-less), PlaygroundPreview, and the REAL deterministic
# ProductQueryOrchestrator + ProductFlowStateStore snapshot semantics, with the opaque signed state
# token round-tripped between turns exactly as the browser does. Only the true external boundaries
# are stubbed: the LLM provider (Marine::Llm::BaseService — intent extraction), the family
# repository, the RAG ResponseGenerator (greeting turn), the KB retrieval used by Gate G, and the
# delivery-only ReplyLocalizer (echoes English so assertions are deterministic; translation has its
# own specs).
#
# The four synthetic turns: a greeting; a school-uniform request; "ada katalog kain baby doll ?";
# "babydoll tidak ada ?". The catalog turns must be CATALOG-GROUNDED / clarify truthfully — never a
# RAG "unavailable" — and the whole flow must create NO Conversation/Message and enqueue no delivery
# job. No real product names/IDs/phrase handling: the family rows and provider fixtures are synthetic.
RSpec.describe 'Marine Playground four-turn catalog acceptance', type: :request do
  include ActiveJob::TestHelper

  class FakeAcceptanceFamilyRepository
    def initialize(rows) = (@rows = rows)

    def resolve_exact(identifier)
      value = identifier.to_s.strip
      return nil if value.empty?

      matches = @rows.select { |row| row[:code].casecmp?(value) || row[:name].casecmp?(value) }
      matches.length == 1 ? matches.first : nil
    end

    def active_candidates(query: nil, limit: 20)
      needle = query.to_s.strip.downcase
      rows = needle.empty? ? @rows : @rows.select { |r| r[:code].downcase.include?(needle) || r[:name].downcase.include?(needle) }
      rows.first(limit)
    end
  end

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'language' => 'en' }) }
  # A usable primary catalog for family BD (Baby Doll), so the direct catalog turn renders the card.
  let!(:catalog_document) do
    create(:marine_document, :product_catalog, assistant: assistant, product_family_code: 'BD',
                                               name: 'Baby Doll Catalog', status: :available)
  end
  # Synthetic families: BD is the only one carrying the 'baby'/'doll' name tokens.
  let(:family_rows) do
    [{ code: 'BD', name: 'Baby Doll' }, { code: 'SU', name: 'School Uniform' }, { code: 'BS', name: 'Bed Sheet' }]
  end
  let(:generator) { instance_double(Marine::Charge::ResponseGenerator) }
  let(:scenario_selector) { instance_double(Marine::Agent::ScenarioSelector) }
  let(:base_service) { instance_double(Marine::Llm::BaseService, configured?: true) }

  before do
    allow(Marine::Catalog::ProductFamilyRepository).to receive(:new).and_return(FakeAcceptanceFamilyRepository.new(family_rows))
    # Gate G retrieval: no exact approved FAQ, so every turn reaches the catalog preview.
    allow(Marine::Cell::KnowledgeBaseService).to receive(:new).and_return(
      instance_double(Marine::Cell::KnowledgeBaseService,
                      retrieve: Marine::Cell::RetrievalResult.empty(fallback_reason: 'no_confident_cell_match'))
    )
    # RAG boundary (only the greeting turn reaches it).
    allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
    allow(generator).to receive(:generate).and_return(
      'response' => 'Hello! How can I help you today?', 'action' => 'reply',
      'agent_name' => assistant.name, 'confidence' => 0.5, 'source_type' => 'manual'
    )
    allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(scenario_selector)
    allow(scenario_selector).to receive(:select).and_return(nil)
    # Delivery-only localizer echoes English so catalog-grounding assertions are deterministic.
    echo = instance_double(Marine::Catalog::ReplyLocalizer)
    allow(Marine::Catalog::ReplyLocalizer).to receive(:new) do |**kwargs|
      @echoed = kwargs[:text]
      echo
    end
    allow(echo).to receive(:call) { @echoed }
    # Provider intent extraction: one stub, branching on the current customer turn embedded in the prompt.
    allow(Marine::Llm::BaseService).to receive(:new).and_return(base_service)
    allow(base_service).to receive(:complete) do |prompt:, system: nil| # rubocop:disable Lint/UnusedBlockArgument
      { ok: true, message: intent_for(prompt.to_s), error: nil }
    end
    clear_enqueued_jobs
  end

  # Synthetic per-turn intent fixtures. Prior turns accumulate in the prompt as history, so branches
  # are checked MOST-RECENT-turn first (each marker is unique to that turn's current message).
  def intent_for(prompt)
    if prompt.include?('babydoll tidak ada') # continuation naming no resolvable family
      { product_related: true, intent: 'catalog', family_mention: nil, customer_language: 'en' }.to_json
    elsif prompt.include?('katalog kain baby doll')
      { product_related: true, intent: 'catalog', family_mention: 'kain baby doll', customer_language: 'en' }.to_json
    elsif prompt.include?('seragam sekolah')
      { product_related: true, intent: 'catalog', family_mention: 'seragam sekolah', customer_language: 'en' }.to_json
    else # greeting ("selamat pagi")
      { product_related: false }.to_json
    end
  end

  def turn(content, history:, state_token:)
    post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
         params: { assistant: { message_content: content, message_history: history, state_token: state_token } },
         headers: admin.create_new_auth_token, as: :json
    JSON.parse(response.body)
  end

  it 'grounds the catalog turns truthfully across four turns with signed state, no side effects' do
    conversations = Conversation.count
    messages = Message.count
    history = []
    token = nil

    # Turn 1 — greeting: not product, falls through to RAG.
    t1 = turn('selamat pagi', history: history, state_token: token)
    expect(t1['response']).to eq('Hello! How can I help you today?')
    token = t1['state_token']
    history += [{ 'role' => 'user', 'content' => 'selamat pagi' }, { 'role' => 'assistant', 'content' => t1['response'] }]

    # Turn 2 — school-uniform request: product, unresolved family -> truthful clarify (never "unavailable").
    t2 = turn('ada seragam sekolah ?', history: history, state_token: token)
    expect(t2['response']).to match(/which product|interested in/i)
    expect(t2['response']).not_to match(/unavailable/i)
    token = t2['state_token'] || token
    history += [{ 'role' => 'user', 'content' => 'ada seragam sekolah ?' }, { 'role' => 'assistant', 'content' => t2['response'] }]

    # Turn 3 — direct catalog request: recovers family BD from the raw turn and renders the read-only
    # catalog card with a TRUTHFUL "would be shared" line (never a RAG "unavailable").
    t3 = turn('ada katalog kain baby doll ?', history: history, state_token: token)
    expect(t3['response']).to eq('The Baby Doll catalog is available and would be shared with the customer in a full conversation.')
    expect(t3['catalog_preview']).to include('family_name' => 'Baby Doll', 'filename' => 'catalog.pdf',
                                             'content_type' => 'application/pdf')
    expect(t3['state_token']).to be_present
    token = t3['state_token']
    history += [{ 'role' => 'user', 'content' => 'ada katalog kain baby doll ?' }, { 'role' => 'assistant', 'content' => t3['response'] }]

    # Turn 4 — "babydoll tidak ada ?": continues the BD flow; the catalog was already shared, so the
    # honest already-shared line — catalog-grounded, never "unavailable".
    t4 = turn('babydoll tidak ada ?', history: history, state_token: token)
    expect(t4['response']).to eq("I've already shared the Baby Doll catalog with you above.")
    expect(t4['response']).not_to match(/unavailable/i)

    # Zero persistent side effects across the whole flow.
    expect(Conversation.count).to eq(conversations)
    expect(Message.count).to eq(messages)
    expect(enqueued_jobs.map { |j| j[:job] }).not_to include(Marine::Conversation::ResponseBuilderJob)
  end

  it 'answers a clean exact catalog query with the read-only card and marks it sent in the token' do
    result = turn('ada katalog kain baby doll ?', history: [], state_token: nil)

    expect(result['catalog_preview']).to include('family_name' => 'Baby Doll')
    expect(result['state_token']).to be_present
    # Following turn on the same family reads the marker and reports already-shared, not a re-offer.
    follow = turn('babydoll tidak ada ?',
                  history: [{ 'role' => 'user', 'content' => 'ada katalog kain baby doll ?' },
                            { 'role' => 'assistant', 'content' => result['response'] }],
                  state_token: result['state_token'])
    expect(follow['response']).to eq("I've already shared the Baby Doll catalog with you above.")
  end

  it 'ignores a tampered state token and fails closed to a fresh flow' do
    result = turn('ada katalog kain baby doll ?', history: [], state_token: 'tampered.garbage.token')

    # A tampered token is discarded (fresh flow), so the direct catalog request still grounds truthfully.
    expect(result['catalog_preview']).to include('family_name' => 'Baby Doll')
  end
end
