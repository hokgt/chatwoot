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
    if prompt.include?('huruf b') # product+catalog but a deliberately AMBIGUOUS family mention ('b' -> BD & BS)
      { product_related: true, intent: 'catalog', family_mention: 'b', customer_language: 'en' }.to_json
    elsif prompt.include?('babydoll tidak ada') # continuation naming no resolvable family
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

    # Turn 4 — "babydoll tidak ada ?": continues the BD flow; the preview card was already shown, so
    # the TRUTHFUL preview-already-shown line (never "already shared a file" — the preview delivered
    # none) — catalog-grounded, never "unavailable".
    t4 = turn('babydoll tidak ada ?', history: history, state_token: token)
    expect(t4['response']).to eq(
      'The Baby Doll catalog preview is already shown above; the file would be shared in a full conversation.'
    )
    expect(t4['response']).not_to match(/unavailable|already shared/i)
    expect(t4).not_to have_key('catalog_preview')

    # Zero persistent side effects across the whole flow.
    expect(Conversation.count).to eq(conversations)
    expect(Message.count).to eq(messages)
    expect(enqueued_jobs.map { |j| j[:job] }).not_to include(Marine::Conversation::ResponseBuilderJob)
  end

  it 'answers a clean exact catalog query with the read-only card and marks it sent in the token' do
    result = turn('ada katalog kain baby doll ?', history: [], state_token: nil)

    expect(result['catalog_preview']).to include('family_name' => 'Baby Doll')
    expect(result['state_token']).to be_present
    # Following turn on the same family reads the marker and reports the preview as already shown
    # (never a re-offer, never a second card, never claiming a file was delivered).
    follow = turn('babydoll tidak ada ?',
                  history: [{ 'role' => 'user', 'content' => 'ada katalog kain baby doll ?' },
                            { 'role' => 'assistant', 'content' => result['response'] }],
                  state_token: result['state_token'])
    expect(follow['response']).to eq(
      'The Baby Doll catalog preview is already shown above; the file would be shared in a full conversation.'
    )
    expect(follow).not_to have_key('catalog_preview')
  end

  it 'ignores a tampered state token and fails closed to a fresh flow' do
    result = turn('ada katalog kain baby doll ?', history: [], state_token: 'tampered.garbage.token')

    # A tampered token is discarded (fresh flow), so the direct catalog request still grounds truthfully.
    expect(result['catalog_preview']).to include('family_name' => 'Baby Doll')
  end

  # Repeated SAME unresolved family clarification, progressed ONLY through the signed state token, must
  # reach occurrence 3 and fail closed to the safe factless handoff preview — never loop or "unavailable".
  it 'progresses a repeated unresolved clarification to a safe handoff on the third occurrence via signed state' do
    # Occurrence 1 — fresh flow opens the family clarification (truthful, never "unavailable").
    t1 = turn('huruf b satu', history: [], state_token: nil)
    expect(t1['response']).to match(/which product you mean/i)
    expect(t1['state_token']).to be_present

    # Occurrence 2 — the SAME unresolved state, carried by the token, still clarifies.
    t2 = turn('huruf b dua', history: [], state_token: t1['state_token'])
    expect(t2['response']).to match(/which product you mean/i)
    expect(t2['state_token']).to be_present

    # Occurrence 3 — the third same-state occurrence hands off to the safe, factless acknowledgement.
    t3 = turn('huruf b tiga', history: [], state_token: t2['state_token'])
    expect(t3['response']).to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
    expect(t3['response']).not_to match(/unavailable/i)
    expect(t3).not_to have_key('catalog_preview')
  end

  # A KNOWN catalog outage surfaced by the REAL orchestrator's repository-failure rescue (a repository
  # raises a CatalogError inside ProductQueryOrchestrator#plan_for_intent) must fail CLOSED to the safe
  # factless preview — never fall through to RAG (which has no catalog knowledge and would fabricate).
  it 'fails closed to the safe factless preview on a real orchestrator/repository catalog outage (never RAG)' do
    outage_repo = instance_double(Marine::Catalog::ProductFamilyRepository)
    allow(outage_repo).to receive(:resolve_exact).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
    allow(outage_repo).to receive(:active_candidates).and_raise(Marine::Catalog::Errors::CatalogUnavailableError)
    allow(Marine::Catalog::ProductFamilyRepository).to receive(:new).and_return(outage_repo)

    result = turn('ada katalog kain baby doll ?', history: [], state_token: nil)

    expect(result['response']).to eq(Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT)
    expect(result['source_type']).to eq('marine_product')
    expect(result).not_to have_key('catalog_preview')
    # Never RAG: the greeting-only RAG generator must not have answered this product turn.
    expect(generator).not_to have_received(:generate)
  end

  # A non-product turn BETWEEN product turns preserves the SAME valid signed state token verbatim, so the
  # ephemeral flow (validated family + catalog-sent marker) survives the RAG turn and the next product
  # turn still recognizes the preview as already shown.
  it 'preserves the same valid signed state token across a non-product RAG turn between product turns' do
    # Product turn — direct catalog request marks catalog_sent in the signed token.
    t1 = turn('ada katalog kain baby doll ?', history: [], state_token: nil)
    expect(t1['catalog_preview']).to include('family_name' => 'Baby Doll')
    product_token = t1['state_token']
    expect(product_token).to be_present

    # Non-product turn — greeting falls through to RAG, which echoes the SAME token unchanged.
    t2 = turn('selamat pagi', history: [], state_token: product_token)
    expect(t2['response']).to eq('Hello! How can I help you today?')
    expect(t2['state_token']).to eq(product_token)

    # Next product turn on the preserved token still sees the flow: preview already shown, no new card.
    t3 = turn('babydoll tidak ada ?',
              history: [{ 'role' => 'user', 'content' => 'ada katalog kain baby doll ?' },
                        { 'role' => 'assistant', 'content' => t1['response'] }],
              state_token: t2['state_token'])
    expect(t3['response']).to eq(
      'The Baby Doll catalog preview is already shown above; the file would be shared in a full conversation.'
    )
    expect(t3).not_to have_key('catalog_preview')
  end
end
