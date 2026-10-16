# frozen_string_literal: true

require 'rails_helper'

# Shared deterministic product-flow language resolver. The local detector is stubbed so the
# suite is deterministic and independent of CLD3's presence in the test image: each example
# declares exactly which texts detect reliably and to what language. All entity/code values are
# SYNTHETIC (no real catalog code) and no behavior is keyed to any particular code shape.
RSpec.describe Marine::Catalog::ConversationLanguageResolver do
  # Map of text => detector result; anything unlisted detects as unknown/unreliable (a bare
  # product code / slot answer).
  let(:detections) { {} }

  before do
    allow(Marine::Llm::LanguageDetector).to receive(:new) do |text|
      result = detections.fetch(text.to_s, language: 'unknown', reliable: false, confidence: 0.0)
      instance_double(Marine::Llm::LanguageDetector, detect: result)
    end
  end

  def reliable(language)
    { language: language, reliable: true, confidence: 0.99 }
  end

  def user(content)
    { role: 'user', content: content }
  end

  def assistant(content)
    { role: 'assistant', content: content }
  end

  # A customer turn carrying the caller-computed, per-turn trusted catalog tokens (Bug 2). Only
  # these caller-injected tokens may be subtracted from THAT prior turn.
  def user_trusted(content, trusted)
    { role: 'user', content: content, trusted_tokens: trusted }
  end

  def resolve(**)
    described_class.resolve(**)
  end

  describe 'entity/code-only continuation (the reported provider misclassification)' do
    it 'ignores an English provider guess for a bare code and inherits the Indonesian prior history' do
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'ZX-90', provider_language: 'en',
                       context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'treats a MULTI-SEGMENT fresh exact entity candidate (not a slot_value hint) as non-linguistic' do
      # "QLR-2200" carries two 3+ char runs, so a naive token count would call it meaningful; the
      # bounded extracted candidate marks it as the entity it is, regardless of code shape.
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'QLR-2200', provider_language: 'en', entity_candidates: ['QLR-2200'],
                       context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'does not trust even a RELIABLE local detection of a bare entity (no code sets the language)' do
      # The code itself detects reliably as English, but an entity-only turn trusts neither the
      # provider nor CLD3 for that entity — it inherits the prior customer language instead.
      detections['NORDA-5000'] = reliable('en')
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'NORDA-5000', provider_language: nil, entity_candidates: ['NORDA-5000'],
                       context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'inherits English when the prior customer history is English (entity provider guess ignored)' do
      detections['what is the price please'] = reliable('en')

      result = resolve(text: 'ZX-90', provider_language: 'id',
                       context: [user('what is the price please')])

      expect(result.language).to eq('en')
    end
  end

  describe 'trusted catalog tokens close the incomplete-extraction gap (session defect repro)' do
    # The reported defect: an all-Indonesian conversation, the turn "satin velvet kakak" (a product
    # name plus a term of address), answered in the WRONG language because the provider guessed "no"
    # for that turn and the extractor had returned an EMPTY family_mention, so the product-name tokens
    # survived as "linguistic evidence". The caller now injects the trusted catalog tokens for the
    # product name so those tokens are subtracted and the turn correctly inherits the prior customer
    # language. Synthetic — "no" stands in for the volatile provider guess.
    it 'subtracts injected trusted tokens so the product-name turn inherits the Indonesian prior history' do
      detections['halo kak mau tanya produknya'] = reliable('id')

      result = resolve(text: 'satin velvet kakak', provider_language: 'no', entity_candidates: [],
                       trusted_tokens: %w[satin velvet], context: [user('halo kak mau tanya produknya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    # Companion regression guard on the OPENER path (where the current turn still decides, as there is
    # no sticky prior history): with NO trusted tokens AND the same empty extraction, the two
    # product-name tokens survive as "evidence", the opener is NOT entity-only, and the volatile provider
    # guess fixes the opener language. This is exactly the gap the injected trusted tokens close.
    it 'without trusted tokens an opener product-name turn still takes the volatile provider guess (the gap)' do
      result = resolve(text: 'satin velvet kakak', provider_language: 'no', entity_candidates: [])

      expect(result.language).to eq('no')
      expect(result.reason).to eq(:current_turn)
    end

    it 'a product-naming English sentence mid-Indonesian conversation stays "id" (sticky, no switch)' do
      # "is satin velvet available in blue please" subtracts the product tokens yet retains meaningful
      # wording; even so, the reliable Indonesian prior history is sticky and the turn does NOT switch.
      detections['halo kak mau tanya produknya'] = reliable('id')

      result = resolve(text: 'is satin velvet available in blue please', provider_language: 'en',
                       trusted_tokens: %w[satin velvet], context: [user('halo kak mau tanya produknya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    it 'the SAME product-naming English sentence as an OPENER (no reliable history) yields "en"' do
      result = resolve(text: 'is satin velvet available in blue please', provider_language: 'en',
                       trusted_tokens: %w[satin velvet])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end

    it 'a ZERO-residue pure product-name turn with NO history fails closed to nil' do
      # Every word token is a trusted catalog token, so the residue is EMPTY — a pure product name
      # carries no linguistic content for either the provider or CLD3 and the provider guess is ignored.
      result = resolve(text: 'satin velvet', provider_language: 'no', trusted_tokens: %w[satin velvet])

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end
  end

  # The reported opener gap: a current product-bearing opener ("Baby doll ada?") whose authoritative
  # Catalog subtraction leaves exactly ONE genuine non-product residue token ("ada"). That single
  # residue token IS real linguistic content the upstream provider read, so when there is no reliable
  # prior customer language to be sticky to the normalized provider language is honored. This is
  # GENERIC — one residue token is enough for the provider regardless of which language it named — but
  # the LOCAL detector still needs the stricter >= 2 residue tokens before its reading is trusted, and
  # a ZERO-residue bare product/code still rejects the provider entirely.
  describe 'opener provider language is honored on one meaningful residue token (reported gap)' do
    it 'honors an Indonesian provider guess for a one-residue product opener (reason current_turn)' do
      # "baby doll ada" minus trusted baby/doll leaves the single residue token "ada".
      result = resolve(text: 'baby doll ada', provider_language: 'id', trusted_tokens: %w[baby doll])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:current_turn)
    end

    it 'honors an English provider guess for the same one-residue shape (generic, not id-specific)' do
      result = resolve(text: 'baby doll ada', provider_language: 'en', trusted_tokens: %w[baby doll])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end

    it 'still ignores the provider for a ZERO-residue bare product and falls to configured' do
      # "baby doll" minus trusted baby/doll leaves NO residue token: provider still rejected.
      result = resolve(text: 'baby doll', provider_language: 'id', trusted_tokens: %w[baby doll],
                       configured_language: 'en')

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:configured)
    end

    it 'still ignores the provider for a ZERO-residue bare code with no fallback (unresolved)' do
      result = resolve(text: 'ZX-90', provider_language: 'en')

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end

    it 'does NOT invoke the local detector for a one-residue turn when the provider is silent' do
      # Provider nil + a single residue token is below the detector's >= 2 bar: CLD3 is never consulted
      # for the lone residue token and the turn falls through to the configured language unchanged.
      result = resolve(text: 'baby doll ada', provider_language: nil, trusted_tokens: %w[baby doll],
                       configured_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:configured)
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('ada')
    end

    it 'keeps a reliable prior customer language sticky over a one-residue current provider language' do
      detections['halo berapa harganya kak'] = reliable('id')

      result = resolve(text: 'baby doll ada', provider_language: 'en', trusted_tokens: %w[baby doll],
                       context: [user('halo berapa harganya kak')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end
  end

  describe 'strict sticky: a reliable prior customer language outranks the current turn (no switch)' do
    # Product decision (final): the reply language is fixed by the customer's PRIOR history and never
    # switches mid-conversation. A meaningful current turn in the OTHER language does NOT flip a
    # conversation that already has a reliable prior customer language.
    it 'does NOT switch on a candidate PLUS meaningful English wording over Indonesian history' do
      detections['halo apa kabar semuanya'] = reliable('id')

      result = resolve(text: 'QLR-2200 what is the price please', provider_language: 'en',
                       entity_candidates: ['QLR-2200'], context: [user('halo apa kabar semuanya')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    # (a) a full meaningful English sentence mid-Indonesian conversation stays Indonesian.
    it 'keeps "id" for a meaningful English turn mid-Indonesian conversation' do
      detections['halo kak mau tanya produk ini'] = reliable('id')

      result = resolve(text: 'what is the total price for this item', provider_language: 'en',
                       context: [user('halo kak mau tanya produk ini')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end

    # (b) symmetric: a full meaningful Indonesian sentence mid-English conversation stays English.
    it 'keeps "en" for a meaningful Indonesian turn mid-English conversation (symmetric)' do
      detections['hello could you help me today'] = reliable('en')

      result = resolve(text: 'berapa harga produk ini semua', provider_language: 'id',
                       context: [user('hello could you help me today')])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:prior_customer)
    end

    # (c) a mid-conversation provider MISCLASSIFICATION cannot hijack the sticky history.
    it 'ignores a provider misclassification mid-conversation — reliable Indonesian history wins' do
      detections['halo berapa harganya kak'] = reliable('id')

      result = resolve(text: 'what is the price please', provider_language: 'no',
                       context: [user('halo berapa harganya kak')])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
    end
  end

  describe 'current turn decides ONLY when there is no reliable prior customer language (openers)' do
    it 'keeps the current-turn provider language for a meaningful Indonesian opener' do
      result = resolve(text: 'Berapa harga produk ini?', provider_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:current_turn)
    end

    it 'keeps the current turn even when it also supplies a slot value (opener)' do
      # A slot answer that is itself a meaningful sentence is NOT erased just because it answered a
      # slot: entity/slot-only content is the condition, not a scope label. With no reliable prior
      # history the current turn still decides, and the surrounding real wording keeps it authoritative.
      result = resolve(text: 'yes please give me the blue one', provider_language: 'en', entity_candidates: ['blue'])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end

    it 'falls back to a reliable local detection of the current turn when the provider is silent' do
      detections['Boleh minta harganya semuanya?'] = reliable('id')

      result = resolve(text: 'Boleh minta harganya semuanya?', provider_language: nil)

      expect(result.language).to eq('id')
    end

    # (d) opener: no history, a meaningful English turn fixes the opener language to English.
    it 'fixes a meaningful English opener to "en" (:current_turn)' do
      result = resolve(text: 'what is the price of this item please', provider_language: 'en')

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end

    # (e) unreadable/noisy history (no reliable prior CUSTOMER turn) lets the current turn decide.
    it 'lets the current turn decide when the history carries no reliable customer language' do
      detections['what is the price please'] = reliable('en')

      # An assistant-only turn plus an unreliable (undetectable) customer turn: no sticky prior language.
      context = [assistant('willkommen'), user('xy')]
      result = resolve(text: 'what is the price please', provider_language: 'en', context: context)

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:current_turn)
    end
  end

  describe 'nearest reliable customer turn wins in mixed bounded history' do
    it 'prefers the newest reliable customer turn' do
      detections['what is the price please'] = reliable('en')
      detections['halo berapa harganya semuanya'] = reliable('id')

      # Oldest -> newest; the newest customer turn is Indonesian.
      context = [user('what is the price please'), assistant('The price is ...'), user('halo berapa harganya semuanya')]

      expect(resolve(text: 'ZX-90', provider_language: 'en', context: context).language).to eq('id')
    end

    it 'flips with the ordering when the newest customer turn is English' do
      detections['what is the price please'] = reliable('en')
      detections['halo berapa harganya semuanya'] = reliable('id')

      context = [user('halo berapa harganya semuanya'), assistant('...'), user('what is the price please')]

      expect(resolve(text: 'ZX-90', provider_language: 'en', context: context).language).to eq('en')
    end

    it 'uses the customer language resolved on the active flow instead of re-detecting a prior turn' do
      detections['halo saya ingin bertanya produk'] = reliable('id')
      detections['stok masih'] = reliable('sm')
      context = [user('halo saya ingin bertanya produk'), assistant('...'), user('stok masih')]

      result = resolve(text: 'ZX-90', provider_language: 'sm', context: context, sticky_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new)
    end
  end

  describe 'assistant/history turns never determine customer language' do
    it 'ignores an assistant turn even when it is the only reliably detectable language' do
      detections['Guten Tag, wie kann ich Ihnen helfen?'] = reliable('de')

      result = resolve(text: 'ZX-90', provider_language: 'en',
                       context: [assistant('Guten Tag, wie kann ich Ihnen helfen?')])

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end

    it 'prefers the configured language over an assistant-only detectable language' do
      detections['Guten Tag zusammen heute'] = reliable('de')

      result = resolve(text: 'ZX-90', provider_language: 'en', configured_language: 'en',
                       context: [assistant('Guten Tag zusammen heute')])

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:configured)
    end

    it 'ignores role-less context entries (unknowable role, fail closed)' do
      detections['halo berapa harganya semuanya'] = reliable('id')

      result = resolve(text: 'ZX-90', provider_language: 'en',
                       context: ['halo berapa harganya semuanya', { content: 'halo berapa harganya semuanya' }])

      expect(result.language).to be_nil
    end
  end

  describe 'configured-language fallback and fail-closed behavior' do
    it 'falls back to the configured assistant language when no customer language is reliable' do
      result = resolve(text: 'ZX-90', provider_language: 'en', configured_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:configured)
    end

    it 'returns nil (fail closed) when nothing resolves — never forcing English or Indonesian' do
      result = resolve(text: 'ZX-90', provider_language: 'en')

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end

    it 'preserves a valid-but-unsupported current language instead of forcing a supported one' do
      result = resolve(text: 'Quel est le prix de ce produit?', provider_language: 'fr')

      expect(result.language).to eq('fr')
    end
  end

  describe 'alias canonicalization' do
    it 'canonicalizes the deprecated Indonesian alias in -> id from the provider' do
      result = resolve(text: 'Berapa harga produk ini?', provider_language: 'in')

      expect(result.language).to eq('id')
    end

    it 'canonicalizes a deprecated alias from a prior customer turn detection' do
      detections['halo berapa harganya semuanya'] = reliable('in')

      result = resolve(text: 'ZX-90', provider_language: 'en', context: [user('halo berapa harganya semuanya')])

      expect(result.language).to eq('id')
    end
  end

  # Bug 2 — a PRIOR customer turn that is only a Catalog product name (e.g. "linen flow") must not be
  # passed raw to CLD3 and poison the strict-sticky language. The CALLER computes the per-turn trusted
  # catalog tokens from THAT turn's own content and attaches them to the context entry; the resolver
  # subtracts them before deciding whether the prior turn carries meaningful linguistic residue. A turn
  # with too little residue is skipped WITHOUT a CLD3 detection; the next older customer turn is tried.
  describe 'Bug 2: per-turn trusted catalog tokens on prior customer turns' do
    # A. Oldest->newest: "berapa harganya" then product-only "linen flow"; current bare code "lf-3".
    # The newest product-only prior is skipped (no CLD3) and the older Indonesian prior wins.
    it 'skips a product-only newest prior and detects the older Indonesian prior (A)' do
      detections['berapa harganya'] = reliable('id')
      detections['linen flow'] = reliable('nl') # the runtime poison: if passed raw, CLD3 says nl

      context = [user_trusted('berapa harganya', []), user_trusted('linen flow', %w[linen flow])]
      result = resolve(text: 'lf-3', provider_language: nil, context: context, configured_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('linen flow')
    end

    # B. Only prior "baby doll ada"; trusted baby/doll leaves one residue token -> skipped; configured wins.
    it 'skips a product-name prior leaving one residue token and falls to configured (B)' do
      context = [user_trusted('baby doll ada', %w[baby doll])]
      result = resolve(text: 'ada warna merah?', provider_language: nil, context: context, configured_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:configured)
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('baby doll ada')
    end

    # C. Every prior turn is product-only -> all skipped; configured id wins.
    it 'skips every product-only prior and falls to configured (C)' do
      context = [user_trusted('linen flow', %w[linen flow]), user_trusted('baby doll', %w[baby doll])]
      result = resolve(text: 'lf-3', provider_language: nil, context: context, configured_language: 'id')

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:configured)
    end

    # D. Every prior turn is product-only and NO configured language -> unresolved (fail closed).
    it 'resolves to unresolved when every prior is product-only and nothing is configured (D)' do
      context = [user_trusted('linen flow', %w[linen flow]), user_trusted('baby doll', %w[baby doll])]
      result = resolve(text: 'lf-3', provider_language: nil, context: context)

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end

    # E. "I want fabric" then newest product-only "baby doll ada"; the older reliable English wins.
    it 'skips the newest product-only prior and detects the older English prior (E)' do
      detections['I want fabric'] = reliable('en')

      context = [user_trusted('I want fabric', []), user_trusted('baby doll ada', %w[baby doll])]
      result = resolve(text: 'bd-1', provider_language: nil, context: context, configured_language: 'id')

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:prior_customer)
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('baby doll ada')
    end

    # F. A prior turn that retains >= 2 residue tokens after subtraction is NOT skipped; CLD3 reads its
    # linguistic RESIDUE (the product tokens removed), never the full product-bearing text.
    it 'detects a prior from its residue when two residue tokens remain after subtraction (F)' do
      detections['fully available'] = reliable('en')

      context = [user_trusted('linen flow fully available', %w[linen flow])]
      result = resolve(text: 'lf-3', provider_language: nil, context: context, configured_language: 'id')

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:prior_customer)
      expect(Marine::Llm::LanguageDetector).to have_received(:new).with('fully available')
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('linen flow fully available')
    end

    # The per-turn tokens are read from the context turn itself — never from the current @trusted_tokens.
    # The current turn's trusted tokens must NOT erase a prior turn's genuine wording.
    it 'uses each prior turn OWN trusted tokens, not the current-turn trusted tokens' do
      detections['linen flow available'] = reliable('en')

      context = [user_trusted('linen flow available', [])] # this prior carries NO trusted tokens
      result = resolve(text: 'linen flow', provider_language: nil, context: context,
                       trusted_tokens: %w[linen flow], configured_language: 'id')

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:prior_customer)
    end

    # Sanitize the metadata shape: a malformed/non-array/non-string trusted_tokens fails closed to NO
    # subtraction (the prior keeps its full residue) and never creates unbounded token work.
    it 'fails closed on a malformed trusted_tokens shape (no subtraction)' do
      detections['linen flow'] = reliable('en')

      context = [{ role: 'user', content: 'linen flow', trusted_tokens: 'linen flow' }]
      result = resolve(text: 'lf-3', provider_language: nil, context: context, configured_language: 'id')

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:prior_customer)
    end
  end

  # H. Current-turn entity_only? filtering is unchanged: the CURRENT turn still subtracts its own
  # entity_candidates + current trusted_tokens from @text only (regression guard for Bug 2).
  describe 'Bug 2: current-turn filtering is unchanged (regression)' do
    it 'still subtracts current trusted_tokens from the current turn on the opener path' do
      # Without subtraction the two product tokens would be residue and the provider guess would be
      # honored; subtracting them leaves ZERO residue, so the provider is rejected and the turn fails
      # closed — proving the current trusted_tokens are still subtracted from @text.
      result = resolve(text: 'satin velvet', provider_language: 'no', trusted_tokens: %w[satin velvet])

      expect(result.language).to be_nil
      expect(result.reason).to eq(:unresolved)
    end
  end

  # Bug: the resolver must DETECT language from the linguistic residue that remains after authoritative
  # entity/catalog-token subtraction — not merely use the residue as a boolean skip gate and then detect
  # the unfiltered full turn. Passing the full product-bearing text to CLD3 let a product name poison the
  # strict-sticky language (the reported linen-flow conversation answered in Dutch). These examples prove
  # the detector receives the RESIDUE for both prior turns and the current turn.
  describe 'Bug: language detection runs on the linguistic residue, not the full product-bearing text' do
    # The reported session, synthesized: three product turns. The nearest prior "kalo linen flow ada"
    # reads Dutch RELIABLY on its FULL text (the poison), but its residue "kalo ada" is unreliable; the
    # older "baby doll ada" leaves one residue token and is skipped. With no reliable prior, the current
    # Indonesian provider language wins — never the sticky Dutch the full-text reading would have forced.
    it 'does not let a product-bearing prior poison sticky history; current provider id wins (repro)' do
      detections['kalo linen flow ada'] = reliable('nl') # the poison if the FULL prior text reaches CLD3

      context = [user_trusted('baby doll ada', %w[baby doll]),
                 user_trusted('kalo linen flow ada', %w[linen flow])]
      result = resolve(text: 'Berapa harganya', provider_language: 'id', context: context)

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:current_turn)
      # The detector saw the RESIDUE of the nearest prior, never its full product-bearing text.
      expect(Marine::Llm::LanguageDetector).to have_received(:new).with('kalo ada')
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('kalo linen flow ada')
      # The older product-only prior is skipped entirely (one residue token), no detection at all.
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('baby doll ada')
    end

    it 'keeps a prior whose RESIDUE reads reliably English sticky over a current Indonesian turn' do
      detections['is available today'] = reliable('en') # residue of the product-bearing prior

      context = [user_trusted('linen flow is available today', %w[linen flow])]
      result = resolve(text: 'berapa harganya produk ini', provider_language: 'id', context: context)

      expect(result.language).to eq('en')
      expect(result.reason).to eq(:prior_customer)
      expect(Marine::Llm::LanguageDetector).to have_received(:new).with('is available today')
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('linen flow is available today')
    end

    it 'falls through to an older reliable prior residue when the nearest residue is unreliable' do
      detections['halo mau tanya produk'] = reliable('id') # older prior, reliable
      # nearest residue "kain warna" is unlisted -> unreliable, so it is not sticky

      context = [user_trusted('halo mau tanya produk', []),
                 user_trusted('satin velvet kain warna', %w[satin velvet])]
      result = resolve(text: 'bd-1', provider_language: nil, context: context)

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:prior_customer)
      expect(Marine::Llm::LanguageDetector).to have_received(:new).with('kain warna')
    end

    it 'lets the current provider language win when no prior is reliable and the current residue is meaningful' do
      context = [user_trusted('baby doll', %w[baby doll])] # product-only prior, skipped
      result = resolve(text: 'satin velvet apakah masih tersedia', provider_language: 'id',
                       trusted_tokens: %w[satin velvet], context: context)

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:current_turn)
    end

    it 'detects the current turn from its RESIDUE when the provider is silent (not the full product text)' do
      detections['apakah masih tersedia warna'] = reliable('id')

      result = resolve(text: 'satin velvet apakah masih tersedia warna', provider_language: nil,
                       trusted_tokens: %w[satin velvet])

      expect(result.language).to eq('id')
      expect(result.reason).to eq(:current_turn)
      expect(Marine::Llm::LanguageDetector).to have_received(:new).with('apakah masih tersedia warna')
      expect(Marine::Llm::LanguageDetector).not_to have_received(:new).with('satin velvet apakah masih tersedia warna')
    end
  end

  describe 'bounded context only (no DB / no provider call)' do
    it 'consults only the supplied context and never constructs a translation/provider client' do
      # The only collaborator it may touch is the local detector; assert no other Marine LLM
      # service is instantiated (no extra provider call).
      expect(Marine::Llm::BaseService).not_to receive(:new)

      resolve(text: 'ZX-90', provider_language: 'en', context: [], configured_language: 'en')
    end
  end
end
