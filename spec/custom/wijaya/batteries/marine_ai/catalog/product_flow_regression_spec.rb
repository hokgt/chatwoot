# frozen_string_literal: true

require 'rails_helper'

# Phase 7 — Cross-component REGRESSION invariants for the deterministic product path.
#
# Per-component specs prove the orchestrator, renderer, and job in isolation. This spec
# stitches the REAL orchestrator + REAL ReplyRenderer + the REAL job text/metadata mapping
# together and proves the end-to-end safety contract that spans them:
#
#   * adversarial repository data (extra columns, a raw quantity, SQL-ish strings) never
#     reaches the frozen plan OR the customer-facing text;
#   * malformed catalog candidates are stripped/bounded before the plan;
#   * every ReplyRenderer descriptor kind maps to a non-empty, fact-safe deterministic
#     string (no kind can fall through to nil or leak a raw fact); and
#   * a product reply carries only the safe marine_product metadata — never citations,
#     confidence, or a raw catalog fact.
RSpec.describe 'Marine product flow cross-component regression' do
  let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }
  let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }

  # REAL renderer + REAL orchestrator over injected fakes.
  let(:orchestrator) do
    Marine::Catalog::ProductQueryOrchestrator.new(
      repositories: { family: family_repository, variant: variant_repository,
                      price: price_repository, stock: stock_repository },
      variant_resolver: variant_resolver, reply_renderer: Marine::Catalog::ReplyRenderer.new
    )
  end
  let(:job) { Marine::Conversation::ResponseBuilderJob.new }

  before do
    allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Impeller')
    allow(family_repository).to receive(:active_candidates).and_return([])
    allow(variant_repository).to receive(:attribute_names).and_return(%w[Size])
    allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'C-1')
    allow(price_repository).to receive(:price_for).and_return(status: :unavailable)
    allow(stock_repository).to receive(:status_for).and_return(:empty)
  end

  def price_intent
    { product_related: true, intent: 'price', family_mention: 'Impeller', explicit_child_code: 'C-1',
      attribute_candidates: [], requires_exact_variant: true, family_changed: false, multiple_numeric_candidates: false }
  end

  def deep_values(node)
    case node
    when Hash then node.flat_map { |k, v| [k, *deep_values(v)] }
    when Array then node.flat_map { |v| deep_values(v) }
    else [node]
    end
  end

  describe 'adversarial repository fields never reach the plan or the customer text' do
    it 'copies only the three approved price fields and drops every injected extra' do
      allow(price_repository).to receive(:price_for).and_return(
        status: :available, price_list_rate: '10.00', currency: 'USD', uom: 'ea',
        secret_cost: 99_999, raw_stock_qty: 42, sql: 'DROP TABLE item;--', warehouse: 'W-1'
      )

      plan = orchestrator.plan_for_intent(intent: price_intent, flow: nil)

      expect(plan[:reply].keys).to match_array(%i[kind price_list_rate currency uom])
      leaked = [99_999, 42, 'DROP TABLE item;--', 'W-1']
      expect(deep_values(plan)).not_to include(*leaked)

      text = job.send(:product_reply_text, plan)
      expect(text).to eq('The price is USD 10.00 per ea.')
      %w[99999 42 DROP W-1].each { |secret| expect(text).not_to include(secret) }
    end

    it 'strips malformed / oversized family candidate fields before the plan' do
      allow(family_repository).to receive(:resolve_exact).and_return(nil)
      # Two candidates keep this AMBIGUOUS so it stays on the clarify_family path (a lone
      # active candidate is legitimately promoted); the adversarial fields must still be stripped.
      allow(family_repository).to receive(:active_candidates).and_return(
        [{ code: 'FAM-1', name: 'A' * 500, cost: 999, sql: 'SELECT 1' }, { code: 'FAM-2', name: 'B' }]
      )

      plan = orchestrator.plan_for_intent(intent: price_intent.merge(explicit_child_code: nil), flow: nil)

      expect(plan[:action]).to eq(:clarify_family)
      candidate = plan[:reply][:candidates].first
      expect(candidate.keys).to match_array(%i[code name])
      expect(candidate[:code]).not_to match(/[[:cntrl:]]/)
      expect(candidate[:name].length).to be <= 120
      expect(deep_values(plan)).not_to include(999, 'SELECT 1')
    end
  end

  describe 'deterministic text map is exhaustive and fact-safe over every renderer kind' do
    let(:renderer) { Marine::Catalog::ReplyRenderer.new }

    # A representative real descriptor for each renderer kind, built by the renderer itself.
    def descriptor_for(kind)
      case kind
      when :parent_info then renderer.parent_info(code: 'FAM-1', name: 'Impeller')
      when :catalog then renderer.catalog(code: 'FAM-1', name: 'Impeller')
      when :variant_info then renderer.variant_info({ code: 'FAM-1' }, 'C-1')
      when :price_available then renderer.price_available(price_list_rate: '10.00', currency: 'USD', uom: 'ea')
      when :clarify_family then renderer.clarify_family([{ code: 'FAM-1', name: 'Impeller' }])
      when :clarify_variant then renderer.clarify_variant(%w[Size])
      else renderer.public_send(kind)
      end
    end

    it 'maps every ReplyRenderer::KINDS descriptor to a non-empty deterministic string' do
      covered = Marine::Catalog::ReplyRenderer::KINDS.map do |kind|
        plan = { action: :reply, reply: descriptor_for(kind), state: { operation: :none, changes: {} } }
        text = job.send(:product_reply_text, plan)

        expect(text).to be_a(String)
        expect(text).not_to be_empty
        expect(text).not_to match(/\d/) if kind.to_s.start_with?('stock_') # stock is never a quantity
        kind
      end

      expect(covered).to match_array(Marine::Catalog::ReplyRenderer::KINDS)
    end

    it 'renders a safe generic prompt (never nil) for an unknown descriptor kind' do
      plan = { action: :reply, reply: { kind: :something_unexpected }, state: { operation: :none, changes: {} } }

      expect(job.send(:product_reply_text, plan)).to eq('Could you share a little more detail about the product you need?')
    end
  end

  describe 'outgoing product reply metadata is allowlisted and fact-free' do
    let(:messages) { double('messages') }
    let(:conversation) { double('conversation', account_id: 11, inbox_id: 22, messages: messages) }
    let(:assistant) { double('assistant') }

    it 'attaches only the safe marine_product source markers — no citations/confidence/raw facts' do
      job.instance_variable_set(:@conversation, conversation)
      job.instance_variable_set(:@assistant, assistant)
      plan = { action: :reply, reply: { kind: :stock_available }, state: { operation: :none, changes: {} } }

      expect(messages).to receive(:create!).with(
        hash_including(
          message_type: :outgoing, content: 'Good news — that item is currently in stock.',
          additional_attributes: { source_type: 'marine_product', orchestration_path: 'product' }
        )
      )

      job.send(:create_product_reply, plan)
    end
  end
end
