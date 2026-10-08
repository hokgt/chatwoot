# frozen_string_literal: true

require 'rails_helper'

# Group D — a non-vacuous continuity proof that the price_range proposed-state-transition persisted on
# Turn 1 lets Turn 2 resolve a BARE exact child code WITHOUT the family being repeated. It wires the
# REAL Marine::Backend::CatalogCandidateResolver (synthetic family/variant repositories — no catalog
# DB) and the REAL Marine::Catalog::ProductFlowStateStore on a persisted Conversation, applying the
# exact :start operation the AuthorityCoordinator/job seam would. No live provider/catalog is touched.
RSpec.describe 'Marine price_range state-transition continuity', type: :model do
  let(:conversation) { create(:conversation) }
  let(:family_repo) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_repo) { instance_double(Marine::Catalog::VariantRepository) }
  let(:resolver) { Marine::Backend::CatalogCandidateResolver.new(family_repository: family_repo, variant_repository: variant_repo) }

  def store
    Marine::Catalog::ProductFlowStateStore.new(conversation: conversation.reload)
  end

  # BD is the only exact family; BD-01 is its only exact child.
  def stub_catalog
    allow(family_repo).to receive(:resolve_exact_any) do |candidates|
      candidates.include?('BD') ? { status: :resolved, code: 'BD', name: 'Santorini' } : { status: :missing }
    end
    allow(variant_repo).to receive(:resolve_child_any) do |family_code, candidates|
      family_code == 'BD' && candidates.include?('BD-01') ? { status: :resolved, code: 'BD-01' } : { status: :missing }
    end
  end

  before { stub_catalog }

  it 'Turn 1 writes the family state; Turn 2 bare child resolves via the state family (family never repeated)' do
    # Turn 1 — an explicit family range turn resolves the exact family BD.
    turn1 = resolver.call(trigger: 'berapa kisaran harga BD', flow_state: store.current_for_planning)
    expect(turn1.status).to eq(:exact_family)
    expect(turn1.family_code).to eq('BD')

    # Apply the coordinator/job :start transition (fresh family state) exactly as finalize would.
    store.start!('validated_family' => turn1.family_code)
    expect(store.current['validated_family']).to eq('BD')

    # Turn 2 — the customer sends ONLY the bare child code; the family is NOT in the trigger.
    turn2 = resolver.call(trigger: 'BD-01', flow_state: store.current_for_planning)
    expect(turn2.status).to eq(:exact_child)
    expect(turn2.family_code).to eq('BD')
    expect(turn2.child_code).to eq('BD-01')
    expect(turn2.source).to eq(:flow_state) # resolved via the persisted family, not a repeated mention
  end

  it 'Turn 2 fails closed (no guess) when the bare turn resolves no exact child under the state family' do
    store.start!('validated_family' => 'BD')

    result = resolver.call(trigger: 'apa kabar', flow_state: store.current_for_planning)

    expect(result.status).to eq(:no_catalog_match)
    expect(result.reason).to eq(:candidate_context_insufficient)
  end

  it 'a Turn-2 forged/unknown family mention is rejected and the Turn-1 family state is retained' do
    store.start!('validated_family' => 'BD')

    # 'ZZZ' is not an exact family and resolves no child under BD -> no match; no transition would be
    # produced, so nothing overwrites the persisted BD family.
    result = resolver.call(trigger: 'kisaran harga ZZZ', flow_state: store.current_for_planning)

    expect(result.status).to eq(:no_catalog_match)
    expect(store.current['validated_family']).to eq('BD')
  end
end
