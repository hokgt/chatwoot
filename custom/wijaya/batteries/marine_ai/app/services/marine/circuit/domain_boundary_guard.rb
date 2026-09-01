# The single shared Textilindo domain / security decision, called from the ONE post-product,
# pre-RAG fallthrough in Marine::Agent::Runner so BOTH surfaces — the conversation ResponseBuilderJob
# path and the source-less Playground preview — reach the identical business/security conclusion.
#
# Contract:
#   * call(query:, history:) returns nil to ALLOW the turn (the runner continues to the unchanged
#     general RAG ResponseGenerator), or a delivery-compatible payload Hash to DENY it.
#   * A denied turn NEVER enters general RAG. It is answered by a dynamic, safe refusal/redirect
#     (Marine::Circuit::BoundaryReplyComposer) — ONE generation attempt — that is then independently
#     checked by a model-free local structural validator (Marine::Circuit::BoundaryReplyValidator)
#     before delivery; on any generation/validation failure — or when classification itself could not
#     be trusted — it falls closed to ONE short generic safe reply. Because the denied path makes at
#     most the classifier's call plus that one generation (no validator call, no retry), it stays well
#     inside the Playground controller's fixed 12-second budget and returns an HTTP 200 refusal.
#
# The guard is fail-CLOSED on every uncertain state — including an unconfigured / malformed / erroring
# Marine LLM. A turn that reaches this shared seam has already passed product/catalog/stock/price and
# EXACT approved-FAQ (Gate G) short-circuits upstream, so the only thing beyond it is general RAG; if
# the boundary cannot be trusted (classifier unconfigured or failing) the turn must NOT be allowed to
# fall through into RAG. Instead it is denied with the single safe fallback. The prior fail-OPEN on an
# unconfigured LLM has been removed: allowing an unclassified turn into ResponseGenerator is not an
# acceptable security posture even when RAG would itself degrade.
#
# Never logs the query, history, candidate, or any internal control text — only the event and the
# allowlisted category/reason.
class Marine::Circuit::DomainBoundaryGuard
  LOG_PREFIX = '[Marine::Circuit::DomainBoundaryGuard]'.freeze
  SOURCE_TYPE = 'domain_boundary'.freeze
  ORCHESTRATION_PATH = 'domain_boundary'.freeze
  # A single dynamic generation attempt: on a blank/invalid candidate the guard falls closed to the
  # one safe fallback rather than retrying, keeping a denied Playground turn's provider work to the
  # classifier's call plus this one generation (well inside the controller's fixed 12s budget).
  MAX_GENERATION_ATTEMPTS = 1

  # The single short, generic, safe fallback delivered when a denied turn cannot produce a validated
  # dynamic refusal (provider/generator/validator failure) or when classification could not be
  # trusted. One neutral line — NOT a phrase/language dictionary and NOT a canned per-category set.
  SAFE_FALLBACK = 'Sorry, I can only help with Textilindo products and services. How can I help you with those?'.freeze

  def initialize(assistant:, account: nil)
    @assistant = assistant
    @account = account
  end

  # Returns nil (allow) or a deny payload. Never raises.
  def call(query:, history: [])
    return nil if query.blank?
    # Fail CLOSED when the Marine LLM is unconfigured: the boundary cannot be evaluated, so the turn
    # must not be allowed to fall through into general RAG — deny with the single safe fallback (no
    # dynamic refusal, since generation also requires a configured LLM). Product/catalog/stock/price
    # and EXACT approved-FAQ have already short-circuited before this seam and are unaffected.
    return fallback_payload(:unconfigured) unless llm_configured?

    decision = classifier.classify(query: query, history: Array(history))
    return nil if decision.allowed?

    deny_payload(decision)
  rescue StandardError => e
    capture(e)
    # An unexpected guard failure still fails closed (deny with the safe fallback), never into RAG.
    fallback_payload(:error)
  end

  private

  attr_reader :assistant, :account

  def llm_configured?
    Marine::Llm::BaseService.new(account: account).configured?
  end

  # A denied turn: attempt a validated dynamic refusal for a describable category; otherwise (the
  # :error sentinel, or exhausted attempts) deliver the single safe fallback.
  def deny_payload(decision)
    if decision.describable?
      refusal = dynamic_refusal(decision)
      return reply_payload(refusal, decision.category) if refusal.present?
    end

    log_event('domain_boundary.fallback', category: decision.category)
    fallback_payload(decision.category)
  end

  # Generate a refusal and deliver it ONLY if the separate LOCAL structural validator accepts the exact
  # candidate. One generation attempt (MAX_GENERATION_ATTEMPTS): on a blank or structurally-invalid
  # candidate the caller falls closed to the safe fallback rather than making further provider calls.
  def dynamic_refusal(decision)
    MAX_GENERATION_ATTEMPTS.times do
      candidate = composer.compose(category: decision.category, language: decision.language)
      next if candidate.blank?

      if validator.valid?(candidate: candidate, category: decision.category, language: decision.language)
        log_event('domain_boundary.deny', category: decision.category)
        return candidate
      end
    end
    nil
  end

  # Delivery-compatible reply payload (action 'reply'): the conversation job posts it as a normal
  # Marine reply and the Playground renders it verbatim, so both surfaces deliver the SAME refusal.
  def reply_payload(text, category)
    {
      'response' => text,
      'action' => 'reply',
      'agent_name' => assistant_name,
      'source_type' => SOURCE_TYPE,
      'orchestration_path' => ORCHESTRATION_PATH,
      'domain_boundary_category' => category.to_s,
      'confidence' => 0.0,
      'citations' => [],
      'response_ids' => [],
      'document_ids' => []
    }
  end

  def fallback_payload(category)
    reply_payload(SAFE_FALLBACK, category)
  end

  def assistant_name
    assistant.name if assistant.respond_to?(:name)
  end

  def classifier
    @classifier ||= Marine::Circuit::DomainSecurityDecisionService.new(account: account)
  end

  def composer
    @composer ||= Marine::Circuit::BoundaryReplyComposer.new(account: account)
  end

  # The validator is a model-free local structural check (no account / provider needed).
  def validator
    @validator ||= Marine::Circuit::BoundaryReplyValidator.new
  end

  def capture(error)
    return if account.nil?

    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  # Secret-free single-line logging: only the event and the allowlisted category/reason.
  def log_event(event, **fields)
    parts = fields.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
    Rails.logger.info("#{LOG_PREFIX} event=#{event} #{parts}".strip)
  end
end
