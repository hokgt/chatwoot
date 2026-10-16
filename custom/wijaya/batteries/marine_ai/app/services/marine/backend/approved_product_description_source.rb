# Phase 3 — the APPROVED-ONLY, assistant-scoped product-description evidence source for the
# answer_product_information path. It is the callable the ProductExecutionPlanner invokes to attach a
# RAG description to an ALREADY catalog-authorized listing page; it can NEVER add, rename, or invent a
# product, and it emits a description for a product ONLY when an approved knowledge-base chunk EXACTLY
# names that product's normalized catalog code or name at Unicode alphanumeric boundaries.
#
# It reuses the existing Marine Cell / Knowledge Base / Retriever architecture. Binding is two-staged so
# the permissive retrieval can never leak into the authority decision:
#   1. CANDIDATE RETRIEVAL — one BOUNDED, approved, assistant-scoped query
#      (Marine::Cell::KnowledgeBaseService#approved_mentioning) loads only the approved responses whose
#      QUESTION OR ANSWER contains a code/name on the authorized page (substring ILIKE). No per-code
#      retrieval and no N+1. This stage does NOT authorize anything — substring containment is permissive.
#   2. EXACT IDENTITY VERIFICATION + SNIPPET EXTRACTION — each candidate row's question/answer is split
#      into normalized chunks (sentence/line/paragraph); a chunk is kept for a product ONLY when it names
#      that product's exact code/name at Unicode alphanumeric boundaries AND names no OTHER authorized
#      page product (cross-contamination is rejected, never swapped). A row's kept chunks become that
#      row's snippet; across rows the snippet must be unique or the product fails closed (conflict).
#
# Approved responses are Marine::AssistantResponse rows (question → answer); only the `.approved` scope is
# consulted. It returns CLOSED per-authorized-product evidence only — a plain { code => description } Hash
# of owned, sanitized, byte-bounded Strings for the subset of products with exactly one approved,
# exact-bound description. It fails closed (omitting a product, or returning {}) on a missing assistant, a
# malformed product set, no matching chunk, an ambiguous/conflicting snippet, or any error. A DB row is
# never returned to the caller — only the bounded snippet text — so no row ever reaches Model 2.
class Marine::Backend::ApprovedProductDescriptionSource
  # Aligned with EvidencePacketBuilder::MAX_LISTING_PRODUCTS / MAX_DESCRIPTION_BYTES so what this source
  # emits is exactly what the packet will carry (no silent downstream truncation surprise).
  MAX_PRODUCTS = 20
  MAX_DESCRIPTION_BYTES = 300

  # Splits content into sentence / line / paragraph chunks: a sentence terminator (ASCII + CJK) followed
  # by whitespace, OR any run of line breaks. Chunking keeps a product-specific snippet bounded instead
  # of attaching a whole multi-product response.
  CHUNK_BOUNDARY = /(?<=[.!?。！？])\s+|[\r\n]+/

  # One authorized identity: a normalized code/name key, its boundary-anchored matcher, and the catalog
  # code it belongs to (so a chunk matching both a product's code and name still counts as ONE product).
  Identity = Struct.new(:code, :matcher)

  # A normalized approved chunk: the display text and a case-folded copy used only for matching.
  Chunk = Struct.new(:text, :folded)

  def initialize(assistant:, knowledge_base: nil)
    @assistant = assistant
    @knowledge_base = knowledge_base
  end

  # products: the already catalog-authorized page, each { code:, name? }. Returns { code => description }
  # for ONLY those products with exactly one approved, exact-bound snippet. Never adds a product.
  def call(products)
    return {} unless @assistant && valid_products?(products)

    identities = authorized_identities(products)
    row_chunks = load_rows(products).map { |row| response_chunks(row) }.reject(&:empty?)
    return {} if row_chunks.empty?

    bind_all(products, identities, row_chunks)
  rescue StandardError
    {}
  end

  private

  def bind_all(products, identities, row_chunks)
    products.each_with_object({}) do |product, bound|
      description = bind(product, identities, row_chunks)
      bound[product[:code]] = description if description
    end
  end

  def valid_products?(products)
    products.is_a?(Array) && !products.empty? && products.length <= MAX_PRODUCTS &&
      products.all? { |product| product.is_a?(Hash) && present_string?(product[:code]) }
  end

  # Every authorized code/name on the page as a boundary-anchored matcher tagged with its product code.
  # The page is the ONLY source of authorized identities — nothing from the approved corpus authorizes.
  def authorized_identities(products)
    products.flat_map do |product|
      [product[:code], product[:name]].filter_map do |value|
        normalized = normalize(value)
        Identity.new(product[:code], identity_matcher(normalized)) unless normalized.empty?
      end
    end
  end

  # One bounded approved CANDIDATE query over every normalized code/name key on the authorized page.
  def load_rows(products)
    keys = products.flat_map { |product| [product[:code], product[:name]] }.compact
    knowledge_base.approved_mentioning(keys).to_a
  end

  # One row's question + answer split into normalized, control-free, non-empty chunks.
  def response_chunks(row)
    [row.question, row.answer].flat_map { |value| split_chunks(value) }
  end

  def split_chunks(value)
    return [] unless value.is_a?(String)

    value.split(CHUNK_BOUNDARY).filter_map do |raw|
      text = raw.gsub(/[[:cntrl:]]/, ' ').squeeze(' ').strip
      Chunk.new(text, text.downcase) unless text.empty?
    end
  end

  # The description for ONE product: the single distinct per-row snippet exact-bound to its identity.
  # Zero matching chunks, or two rows disagreeing on the snippet, bind nothing (fail closed).
  def bind(product, identities, row_chunks)
    return nil if identities.none? { |identity| identity.code == product[:code] }

    snippets = row_chunks.filter_map { |chunks| row_snippet(product, identities, chunks) }.uniq
    snippets.length == 1 ? snippets.first : nil
  end

  # The snippet ONE row contributes for a product: its chunks that name EXACTLY this product (and no
  # other authorized page product), joined and byte-bounded. nil when the row names the product nowhere
  # cleanly.
  def row_snippet(product, identities, chunks)
    kept = chunks.select { |chunk| chunk_for_product?(chunk, product, identities) }
    return nil if kept.empty?

    sanitize(kept.map(&:text).join(' '))
  end

  # True only when the chunk names this product's identity and names NO other authorized page product —
  # a chunk mentioning two authorized products is rejected rather than cross-contaminating descriptions.
  # An off-page (unauthorized) identity in the chunk is invisible here, so it is never appended.
  def chunk_for_product?(chunk, product, identities)
    codes = identities.select { |identity| identity.matcher.match?(chunk.folded) }.map(&:code).uniq
    codes.length == 1 && codes.first == product[:code]
  end

  def knowledge_base
    @knowledge_base ||= Marine::Cell::KnowledgeBaseService.new(assistant: @assistant)
  end

  def normalize(value)
    value.to_s.strip.downcase
  end

  # An exact-match matcher anchored at Unicode alphanumeric boundaries, so an embedded/partial
  # occurrence (e.g. "AAA" inside "AAAB") never binds. Built on the already-normalized (downcased) key
  # and matched against the case-folded chunk.
  def identity_matcher(normalized)
    Regexp.new("(?<![[:alnum:]])#{Regexp.escape(normalized)}(?![[:alnum:]])")
  end

  # A fresh, control-free, byte-bounded owned copy of a snippet, or nil when blank.
  def sanitize(value)
    return nil unless value.is_a?(String)

    cleaned = value.gsub(/[[:cntrl:]]/, ' ').strip
    return nil if cleaned.empty?

    cleaned.bytesize <= MAX_DESCRIPTION_BYTES ? cleaned : cleaned.byteslice(0, MAX_DESCRIPTION_BYTES).scrub('')
  end

  def present_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end
end
