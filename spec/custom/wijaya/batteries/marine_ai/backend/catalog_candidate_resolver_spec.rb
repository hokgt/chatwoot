# frozen_string_literal: true

require 'rails_helper'

# Phase 2A — the closed CatalogCandidateResolver seam. Both repositories are injected doubles so no
# catalog DB is touched; these examples pin the §7.3/§7.4 precedence: an exact current family wins, a
# switch never reuses a stale variant, the same family may reuse a revalidated saved child, a bare
# exact child continues under a revalidated state family, the one-token display-name collision guard,
# ambiguity/outage fail closed, and state is NEVER the sole family authority.
RSpec.describe Marine::Backend::CatalogCandidateResolver do
  subject(:resolver) { described_class.new(family_repository: family_repo, variant_repository: variant_repo) }

  let(:family_repo) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_repo) { instance_double(Marine::Catalog::VariantRepository) }

  def active_state(family:, variant: nil)
    { 'status' => 'active', 'validated_family' => family, 'validated_variant' => variant }
  end

  describe 'candidate generation + bounds' do
    it 'returns candidate_context_insufficient for a blank trigger without touching a repository' do
      # No repository method is stubbed, so any lookup would raise — proving a blank trigger
      # short-circuits before the catalog is touched.
      result = resolver.call(trigger: '   ', flow_state: nil)

      expect(result.status).to eq(:no_catalog_match)
      expect(result.reason).to eq(:candidate_context_insufficient)
      expect(result.source).to eq(:none)
    end

    # B1(d) — a short in-budget turn generates a deterministic, byte-bounded candidate set in the
    # documented order (full trigger → tokens → longest-first spans, punctuation preserved) and is
    # passed verbatim to the repository.
    it 'passes a deterministic, byte-bounded candidate set in full-trigger -> tokens -> spans order' do
      captured = nil
      allow(family_repo).to receive(:resolve_exact_any) { |cands|
        captured = cands
        { status: :missing }
      }

      resolver.call(trigger: 'harga FAM-1/A?', flow_state: nil)

      # full trigger, then each token (punctuation preserved); the only 2-token span equals the full
      # trigger and is deduped away.
      expect(captured).to eq(['harga FAM-1/A?', 'harga', 'FAM-1/A?'])
      expect(captured).to all(satisfy { |c| c.bytesize <= described_class::MAX_CANDIDATE_BYTES })
    end

    # B1(b) — a short exact code at the END of a longer turn is never starved: it is a token in the
    # (in-budget) candidate set and resolves.
    it 'resolves a short tail code inside a longer turn when the complete set is within budget' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull')
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :missing)

      result = resolver.call(trigger: 'mau tanya FAM1', flow_state: nil)

      expect(result.status).to eq(:exact_family)
      expect(result.family_code).to eq('FAM1')
    end

    # B1(a) — a >31-token turn (full trigger + 32 distinct tokens already exceeds MAX_CANDIDATES)
    # fails closed BEFORE any repository lookup: a family token early + an exact child token late can
    # NEVER produce a family range/evidence from a silently-truncated set.
    it 'fails closed (no fact dispatch) when a >31-token turn would truncate the candidate set' do
      allow(family_repo).to receive(:resolve_exact_any)
      tokens = ['FAM1'] + (1..30).map { |i| "w#{i}" } + ['FAM1-CHILD'] # 32 tokens

      result = resolver.call(trigger: tokens.join(' '), flow_state: nil)

      expect(result.status).to eq(:no_catalog_match)
      expect(result.reason).to eq(:candidate_context_insufficient)
      expect(family_repo).not_to have_received(:resolve_exact_any)
    end

    # B1(c) — the deterministic longest-first spans of a modest-length turn can themselves overflow
    # the cap even when full+tokens fit; that also fails closed rather than resolving from a
    # truncated span set.
    it 'fails closed when the deterministic spans would overflow the candidate budget' do
      allow(family_repo).to receive(:resolve_exact_any)

      result = resolver.call(trigger: (1..8).map { |i| "t#{i}" }.join(' '), flow_state: nil)

      expect(result.status).to eq(:no_catalog_match)
      expect(result.reason).to eq(:candidate_context_insufficient)
      expect(family_repo).not_to have_received(:resolve_exact_any)
    end

    it 'drops an oversized (> MAX_CANDIDATE_BYTES) candidate rather than slicing it to a prefix' do
      captured = nil
      allow(family_repo).to receive(:resolve_exact_any) { |cands|
        captured = cands
        { status: :missing }
      }
      long = 'x' * (described_class::MAX_CANDIDATE_BYTES + 1)

      resolver.call(trigger: "harga #{long}", flow_state: nil)

      expect(captured).to all(satisfy { |c| c.bytesize <= described_class::MAX_CANDIDATE_BYTES })
      expect(captured).not_to include(long)
      expect(captured).not_to include(long[0, described_class::MAX_CANDIDATE_BYTES]) # never prefix-truncated
    end

    it 'is deep-frozen and immutable' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :missing)
      result = resolver.call(trigger: 'anything', flow_state: nil)

      expect(result).to be_frozen
    end
  end

  describe 'current-turn family precedence' do
    before { allow(variant_repo).to receive(:resolve_child_any).and_return(status: :missing) }

    it 'resolves an exact current family by code (single-token code always authoritative)' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull Series')

      result = resolver.call(trigger: 'FAM1', flow_state: nil)

      expect(result.status).to eq(:exact_family)
      expect(result.source).to eq(:current_turn)
      expect(result.family_code).to eq('FAM1')
    end

    it 'resolves an exact current family by multi-token name' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull Series')

      result = resolver.call(trigger: 'Hull Series', flow_state: nil)

      expect(result.status).to eq(:exact_family)
      expect(result.family_code).to eq('FAM1')
    end

    it 'does NOT let a one-token display-name embedded in a longer turn resolve a family' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'BLUE-CODE', name: 'blue')

      result = resolver.call(trigger: 'i really want the blue sails please', flow_state: nil)

      expect(result.status).to eq(:no_catalog_match)
      expect(result.reason).to eq(:candidate_context_insufficient)
    end

    it 'prefers an exact current child over the family-only range' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull')
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :resolved, code: 'FAM1-CHILD')

      result = resolver.call(trigger: 'FAM1 FAM1-CHILD', flow_state: nil)

      expect(result.status).to eq(:exact_child)
      expect(result.child_code).to eq('FAM1-CHILD')
      expect(result.source).to eq(:current_turn)
    end

    it 'fails closed on an ambiguous exact child identity (never falls to the range)' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull')
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :ambiguous)

      result = resolver.call(trigger: 'FAM1 something', flow_state: nil)

      expect(result.status).to eq(:ambiguous)
      expect(result.reason).to eq(:variant_ambiguous)
    end
  end

  describe 'state interaction' do
    it 'reuses a revalidated saved child only when the current family IS the state family and no current child resolves' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull')
      allow(variant_repo).to receive(:resolve_child_any) do |_family, cands|
        cands == ['SAVED-CHILD'] ? { status: :resolved, code: 'SAVED-CHILD' } : { status: :missing }
      end

      result = resolver.call(trigger: 'FAM1', flow_state: active_state(family: 'FAM1', variant: 'SAVED-CHILD'))

      expect(result.status).to eq(:exact_child)
      expect(result.child_code).to eq('SAVED-CHILD')
      expect(result.source).to eq(:flow_state)
    end

    it 'does NOT reuse a stale saved variant when the current family is a switch' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM2', name: 'Deck')
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :missing)

      result = resolver.call(trigger: 'FAM2', flow_state: active_state(family: 'FAM1', variant: 'SAVED-CHILD'))

      expect(result.status).to eq(:exact_family)
      expect(result.family_code).to eq('FAM2')
      expect(result.child_code).to be_nil
    end

    it 'continues a bare exact child code under a revalidated state family (no current family resolves)' do
      allow(family_repo).to receive(:resolve_exact_any) do |cands|
        cands == ['FAM1'] ? { status: :resolved, code: 'FAM1', name: 'Hull' } : { status: :missing }
      end
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :resolved, code: 'FAM1-CHILD')

      result = resolver.call(trigger: 'FAM1-CHILD', flow_state: active_state(family: 'FAM1'))

      expect(result.status).to eq(:exact_child)
      expect(result.child_code).to eq('FAM1-CHILD')
      expect(result.source).to eq(:flow_state)
    end

    it 'never uses the state family alone (no current family and no current child under state)' do
      allow(family_repo).to receive(:resolve_exact_any) do |cands|
        cands == ['FAM1'] ? { status: :resolved, code: 'FAM1', name: 'Hull' } : { status: :missing }
      end
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :missing)

      result = resolver.call(trigger: 'do you deliver on weekends', flow_state: active_state(family: 'FAM1'))

      expect(result.status).to eq(:no_catalog_match)
      expect(result.reason).to eq(:candidate_context_insufficient)
    end

    it 'ignores an inactive/expired flow state' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :missing)
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :missing)

      result = resolver.call(trigger: 'ordinary prose', flow_state: { 'status' => 'expired', 'validated_family' => 'FAM1' })

      expect(result.status).to eq(:no_catalog_match)
    end

    # B2 — the SAME current family, no current child candidate, but the saved child revalidation is
    # AMBIGUOUS must fail closed to variant_ambiguous, NOT silently fall through to the family range.
    it 'fails closed (variant_ambiguous) on an ambiguous saved-child revalidation (never the range)' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull')
      allow(variant_repo).to receive(:resolve_child_any) do |_family, cands|
        cands == ['SAVED-CHILD'] ? { status: :ambiguous } : { status: :missing }
      end

      result = resolver.call(trigger: 'FAM1', flow_state: active_state(family: 'FAM1', variant: 'SAVED-CHILD'))

      expect(result.status).to eq(:ambiguous)
      expect(result.reason).to eq(:variant_ambiguous)
      expect(result.source).to eq(:flow_state)
    end

    # B3 — with no current family, an AMBIGUOUS state-family revalidation must fail closed to
    # family_ambiguous, NOT degrade to no_catalog_match.
    it 'fails closed (family_ambiguous) on an ambiguous state-family revalidation (not no_catalog_match)' do
      allow(family_repo).to receive(:resolve_exact_any) do |cands|
        cands == ['FAM1'] ? { status: :ambiguous } : { status: :missing }
      end
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :missing)

      result = resolver.call(trigger: 'ordinary question', flow_state: active_state(family: 'FAM1'))

      expect(result.status).to eq(:ambiguous)
      expect(result.reason).to eq(:family_ambiguous)
    end
  end

  describe 'fail-closed statuses' do
    it 'maps a family repository outage to unavailable/catalog_unavailable' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :unavailable)

      result = resolver.call(trigger: 'FAM1', flow_state: nil)

      expect(result.status).to eq(:unavailable)
      expect(result.reason).to eq(:catalog_unavailable)
    end

    it 'maps an ambiguous/duplicate family identity to ambiguous/family_ambiguous' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :ambiguous)

      result = resolver.call(trigger: 'Hull Series', flow_state: nil)

      expect(result.status).to eq(:ambiguous)
      expect(result.reason).to eq(:family_ambiguous)
    end

    it 'maps a child repository outage to unavailable' do
      allow(family_repo).to receive(:resolve_exact_any).and_return(status: :resolved, code: 'FAM1', name: 'Hull')
      allow(variant_repo).to receive(:resolve_child_any).and_return(status: :unavailable)

      result = resolver.call(trigger: 'FAM1 x', flow_state: nil)

      expect(result.status).to eq(:unavailable)
    end
  end

  # Non-vacuous integration: a REAL VariantRepository (only the low-level Connection boundary faked)
  # under a controlled family-repository double. A lower-case child trigger `lf-3` under an ACTIVE LF
  # family must reach exact_child with the authoritative DB child code LF-3 — exercising the real
  # case-insensitive resolve_child_any SQL, not a stub of it.
  describe 'case-insensitive child continuation through the real variant repository' do
    subject(:resolver) { described_class.new(family_repository: family_repo, variant_repository: Marine::Catalog::VariantRepository.new) }

    before do
      allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
      allow(Marine::Catalog::Config).to receive(:qualified_table).and_return('marine_ai.item')
      allow(Marine::Catalog::Config).to receive(:schema).and_return('marine_ai')
      # No current family resolves from the trigger; the active state family LF revalidates.
      allow(family_repo).to receive(:resolve_exact_any) do |cands|
        cands == ['LF'] ? { status: :resolved, code: 'LF', name: 'LF' } : { status: :missing }
      end
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, params|
        family = params[0]
        candidates = params[1..]
        case_insensitive = sql.include?('LOWER(item_code)')
        [{ item_code: 'LF-3', variant_of: 'LF', disabled: false }]
          .select { |r| r[:variant_of] == family && candidates.any? { |c| case_insensitive ? r[:item_code].casecmp?(c) : r[:item_code] == c } }
          .map { |r| { 'code' => r[:item_code] } }
      end
    end

    it 'reaches exact_child with the DB-derived child code LF-3 for a lower-case lf-3 trigger' do
      result = resolver.call(trigger: 'lf-3', flow_state: active_state(family: 'LF'))

      expect(result.status).to eq(:exact_child)
      expect(result.child_code).to eq('LF-3')
      expect(result.source).to eq(:flow_state)
    end
  end
end
