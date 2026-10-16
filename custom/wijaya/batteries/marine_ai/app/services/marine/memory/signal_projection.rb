# frozen_string_literal: true

# Projects final structured execution state to the closed, fact-free memory signal.
# It never reads customer text or rendered prose. Unknown or unproved outcomes fail closed.
class Marine::Memory::SignalProjection
  INTENT_CAPABILITIES = {
    'price' => 'price', 'price_range' => 'price_range', 'stock' => 'stock',
    'parent_info' => 'product_information', 'variant_info' => 'product_information',
    'product_listing' => 'product_listing', 'product_information' => 'product_information',
    'product_overview' => 'company_offerings', 'catalog' => 'catalog_attachment'
  }.freeze
  REPLY_CAPABILITIES = {
    price_available: 'price',
    price_range: 'price_range', stock_available: 'stock', stock_empty: 'stock',
    product_listing: 'product_listing', company_offerings: 'company_offerings'
  }.freeze

  def initialize(response:, backend_result:, public_reply_message_id:, catalog_attachment_delivered: false)
    @response = response
    @backend_result = backend_result
    @public_reply_message_id = public_reply_message_id
    @catalog_attachment_delivered = catalog_attachment_delivered
  end

  def to_h
    requested = requested_capabilities
    delivered = delivered_capabilities(requested)
    {
      status: status_for(requested, delivered),
      requested_capabilities: requested,
      delivered_capabilities: delivered,
      evidence_versions: evidence_versions(delivered),
      public_reply_message_id: public_reply_message_id
    }
  rescue StandardError
    blocking_projection
  end

  private

  attr_reader :response, :backend_result, :public_reply_message_id, :catalog_attachment_delivered

  def requested_capabilities
    (closed_backend_array(:requested_capabilities) + product_requested_capabilities).uniq.sort
  end

  def delivered_capabilities(requested)
    backend = backend_delivery_proven? ? closed_backend_array(:delivered_capabilities) : []
    (backend + product_delivered_capabilities).uniq.select { |capability| requested.include?(capability) }.sort
  end

  def closed_backend_array(method, allowlist: Marine::Memory::Signal::CAPABILITIES)
    return [] unless backend_result.respond_to?(method)

    Array(backend_result.public_send(method)).map(&:to_s)
                                             .select { |value| allowlist.include?(value) }
  end

  def backend_status
    backend_result&.status
  end

  def backend_reason
    backend_result&.reason
  end

  def backend_delivery_proven?
    backend_status == Marine::Backend::ExactPriceCustomerExecution::STATUS_DELIVERABLE &&
      backend_reason == Marine::Backend::ExactPriceCustomerExecution::REASON_ACCEPTED
  end

  def backend_neutral_proven?
    backend_status == Marine::Backend::ExactPriceCustomerExecution::STATUS_NEUTRAL &&
      backend_reason == Marine::Backend::ExactPriceCustomerExecution::REASON_NON_PRODUCT
  end

  def product_plan
    return unless response.is_a?(Hash) && response['product_plan'].is_a?(Hash)

    response['product_plan']
  end

  def product_requested_capabilities
    plan = product_plan
    return [] unless plan

    changes = plan.dig(:state, :changes).to_h
    intents = Array(changes['requested_intents'])
    intents = [changes['current_intent']] if intents.empty?
    from_intents = intents.filter_map { |intent| INTENT_CAPABILITIES[intent.to_s] }
    from_reply = requested_reply_capabilities(plan[:reply])
    from_action = plan[:action] == :send_catalog ? ['catalog_attachment'] : []
    (from_intents + from_reply + from_action).uniq
  end

  # rubocop:disable Metrics/CyclomaticComplexity -- Delivery proof gates intentionally remain explicit.
  def product_delivered_capabilities
    plan = product_plan
    return [] unless plan && public_reply_message_id
    return [] unless %i[reply send_catalog].include?(plan[:action])

    if plan[:action] == :send_catalog
      return ['catalog_attachment'] if catalog_attachment_delivered
      return ['price_range'] if plan[:reply].is_a?(Hash) && plan[:reply][:kind] == :price_range

      return []
    end

    reply_capabilities(plan[:reply])
  end

  # rubocop:enable Metrics/CyclomaticComplexity

  def requested_reply_capabilities(descriptor)
    return [] unless descriptor.is_a?(Hash)
    return Array(descriptor[:parts]).flat_map { |part| requested_reply_capabilities(part) }.uniq if descriptor[:kind] == :composite
    return ['product_information'] if %i[parent_info variant_info].include?(descriptor[:kind])

    reply_capabilities(descriptor)
  end

  # parent_info / variant_info are deliberately absent: catalog identity alone is not
  # approved-description authority. Only an accepted Backend Evidence result may prove delivery.
  def reply_capabilities(descriptor)
    return [] unless descriptor.is_a?(Hash)
    return Array(descriptor[:parts]).flat_map { |part| reply_capabilities(part) }.uniq if descriptor[:kind] == :composite

    capability = REPLY_CAPABILITIES[descriptor[:kind]]
    capability ? [capability] : []
  end

  # rubocop:disable Metrics/CyclomaticComplexity -- Closed status truth table is clearer as guards.
  def status_for(requested, delivered)
    return 'blocking' if blocking_response?
    return 'complete' if requested.any? && delivered.sort == requested.sort
    return 'neutral' if requested.empty? && delivered.empty? && public_reply_message_id && backend_neutral_proven?

    'blocking'
  end

  # rubocop:enable Metrics/CyclomaticComplexity

  def blocking_response?
    return true unless response.is_a?(Hash)

    action = response['action']
    action == 'handoff' || action == 'terminal_no_output' || response['response'] == 'conversation_handoff'
  end

  def evidence_versions(delivered)
    return [] if delivered.empty? || !backend_delivery_proven?

    closed_backend_array(:evidence_versions, allowlist: Marine::Memory::Signal::EVIDENCE_VERSIONS)
  end

  def blocking_projection
    {
      status: 'blocking', requested_capabilities: [], delivered_capabilities: [],
      evidence_versions: [], public_reply_message_id: nil
    }
  end
end
