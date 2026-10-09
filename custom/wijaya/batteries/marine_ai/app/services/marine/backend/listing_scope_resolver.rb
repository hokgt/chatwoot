# Resolves category/product scope for product-listing turns from the bounded current trigger only.
# Both authoritative namespaces are queried independently. Exact product/group identity wins, while
# ambiguity within either namespace or a cross-namespace collision fails closed. If neither exact
# namespace matches, a bounded repository inference may map exact product-name/code tokens to an Item
# Group only when every matching product converges. A nonblank unresolved trigger never broadens.
class Marine::Backend::ListingScopeResolver
  Schema = Marine::Decision::Schema
  MAX_CANDIDATES = Schema::MAX_RAW_ARRAY
  MAX_CANDIDATE_BYTES = Schema::MAX_RAW_CANDIDATE_LENGTH

  STATUS_BROAD = :broad
  STATUS_PRODUCT = :product
  STATUS_ITEM_GROUP = :item_group
  STATUS_AMBIGUOUS = :ambiguous
  STATUS_UNAVAILABLE = :unavailable

  Result = Struct.new(:status, :product, :item_group, keyword_init: true)

  def initialize(repository: nil)
    @repository = repository || Marine::Catalog::ProductListingRepository.new
  end

  def call(trigger:) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity -- explicit fail-closed namespace and inference matrix
    candidates = bounded_candidates(trigger)
    return result(STATUS_AMBIGUOUS) if candidates.nil?
    return result(STATUS_BROAD) if candidates.empty?

    product = @repository.resolve_top_level_any(candidates)
    group = @repository.resolve_item_group_any(candidates)
    return result(STATUS_UNAVAILABLE) if [product, group].any? { |match| match[:status] == :unavailable }
    return result(STATUS_AMBIGUOUS) if [product, group].any? { |match| match[:status] == :ambiguous }

    product_match = product[:status] == :resolved
    group_match = group[:status] == :resolved
    return result(STATUS_AMBIGUOUS) if product_match && group_match
    return result(STATUS_ITEM_GROUP, item_group: group[:item_group]) if group_match

    inferred = @repository.infer_item_group_from_top_level_any(candidates)
    return result(STATUS_UNAVAILABLE) if inferred[:status] == :unavailable
    return result(STATUS_AMBIGUOUS) if inferred[:status] == :ambiguous

    inferred_match = inferred[:status] == :resolved
    return result(STATUS_AMBIGUOUS) if product_match && inferred_match
    return result(STATUS_PRODUCT, product: { code: product[:code], name: product[:name] }) if product_match
    return result(STATUS_ITEM_GROUP, item_group: inferred[:item_group]) if inferred_match

    result(STATUS_AMBIGUOUS)
  rescue Marine::Catalog::Errors::CatalogUnavailableError, StandardError
    result(STATUS_UNAVAILABLE)
  end

  private

  def bounded_candidates(trigger) # rubocop:disable Metrics/CyclomaticComplexity -- bounded contiguous phrase expansion
    text = trigger.to_s.strip
    return [] if text.empty?

    tokens = text.split(/\s+/)
    values = ([text] + tokens).select { |value| value.bytesize <= MAX_CANDIDATE_BYTES }.uniq
    return nil if values.length > MAX_CANDIDATES

    tokens.length.downto(2) do |length|
      (0..(tokens.length - length)).each do |start|
        value = tokens[start, length].join(' ')
        next if value.bytesize > MAX_CANDIDATE_BYTES || values.include?(value)
        return nil if values.length >= MAX_CANDIDATES

        values << value
      end
    end
    values
  end

  def result(status, product: nil, item_group: nil)
    Result.new(status: status, product: product, item_group: item_group).tap do |value|
      product&.each do |key, child|
        key.freeze
        child.freeze
      end&.freeze
      item_group&.freeze
      value.freeze
    end
  end
end
