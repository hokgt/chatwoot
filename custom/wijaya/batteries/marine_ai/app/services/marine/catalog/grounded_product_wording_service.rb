# Phase 6 — fact-protected natural wording for a deterministic product reply ONLY.
#
# The deterministic LOCALIZED product reply is the authoritative delivery fallback and the
# SOLE product/business factual source. This service asks the LLM to rephrase that fallback
# naturally in context, then delivers the candidate ONLY when TWO independent gates accept it:
#   1. Marine::Catalog::ProductFactProtectionValidator (deterministic, runs FIRST) proves the
#      candidate preserves every protected display value and token inventory; then
#      2. a SEPARATE Marine::Charge::FactPreservationValidator LLM call proves the candidate is
#      semantically fact-equivalent to the exact fallback.
# Generation and semantic validation are two distinct LLM calls; the candidate is untrusted and
# never self-certified. An unsupported/malformed descriptor never reaches generation (so no LLM
# call is made). Any generation/validation failure or uncertainty returns nil (a non-delivery
# signal), and the caller delivers its exact deterministic fallback byte-for-byte.
#
# It reuses the canonical Phase 4 greeting policy exactly as the FAQ wording path does: the
# opening/follow-up state grounds Marine::Charge::GreetingContext#interaction_prompt during
# generation, and #enforce runs on the candidate BEFORE either gate so both validators judge —
# and the caller delivers — the exact enforced text (a follow-up opening greeting/salutation is
# removed, an opening wrong-time greeting is normalized, and a follow-up greeting-only reply
# enforces down to blank and fails closed). No greeting phrases/languages/wordlists live here.
# It passes ONLY the deterministic fallback (facts) plus the latest canonical request and bounded
# prior canonical history (conversational relevance) to the LLM — never the plan/state, repository
# rows, raw stock/price internals, IDs, or unrelated data — and logs/persists nothing.
module Marine
  module Catalog
    class GroundedProductWordingService
      # NUL and other unsafe C0/DEL control characters, excluding tab (\t), newline (\n),
      # and carriage return (\r) which are legitimate in prose.
      UNSAFE_CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

      # Provider-enforced generation envelope (RubyLLM #with_schema format): a bare object carrying
      # EXACTLY one string field, "reply". Constraining generation to structured output removes the
      # fenced/markdown/prose/quote SHAPE variance that would otherwise trip the shape gate and drop
      # the natural wording — the structural half of the Gate F stabilization. It is a REQUEST-side
      # control ONLY and never relaxes acceptance: the extracted reply is still untrusted and still
      # passes the shape gate, greeting enforcement, the deterministic ProductFactProtectionValidator,
      # and the SEPARATE semantic validator. A provider that ignores or cannot enforce the schema
      # degrades to a fail-closed nil (the caller delivers its exact deterministic fallback) — see
      # #reply_from_envelope. The reply stays a same-language natural rephrase, so this does NOT
      # require the fallback to appear verbatim; protected facts are enforced by the two gates.
      REPLY_SCHEMA = {
        name: 'contextual_reply',
        strict: true,
        schema: {
          type: 'object',
          additionalProperties: false,
          required: %w[reply],
          properties: { 'reply' => { type: 'string' } }
        }
      }.freeze

      # The two pure binary-availability reply kinds. For these — and ONLY these — the semantic
      # judge is given STOCK_FACT_FOCUS so it anchors materiality on the single in/out boolean. A
      # price+stock :composite is deliberately excluded: it also carries a literal price fact, so it
      # keeps the unscoped rubric (its price is still token-protected deterministically).
      STOCK_KINDS = %i[stock_available stock_empty].freeze

      # Narrowly scoped semantic-judgement guidance for a pure stock-availability reply. The Approved
      # Answer now names the exact validated product/variant identity the availability is FOR, so this
      # focus tells the judge there are TWO material facts — that identity and the binary in/out
      # outcome — and that a Candidate repeating the SAME identity unchanged is PRESERVING it, not
      # adding a fact. That stops the general rubric from over-rejecting faithful, greeting- or
      # framing-bearing rephrasings (relative-time words, pronouns, warm acknowledgements) that keep
      # the exact identity and outcome — the live-acceptance failure — WITHOUT relaxing the flip /
      # uncertainty / extra-fact rejections, and in particular still rejecting a CHANGED, DROPPED, or
      # DIFFERENT identity the Approved Answer does not state. The identity's byte-exact form is also
      # guarded by the deterministic ProductFactProtectionValidator that runs first. It names no
      # language, phrase list, product, or company, and passes no raw customer text.
      STOCK_FACT_FOCUS = <<~PROMPT.strip
        For THIS answer there are exactly two material facts: (1) the specific validated product or variant identity the Approved Answer names — its exact code, model, or name — and (2) one definite binary stock-availability outcome, either in stock or out of stock.
        A Candidate Reply preserves the facts when it keeps that SAME product/variant identity unchanged AND states the SAME availability outcome, whatever its wording, sentence shape, or pronouns, and however it phrases the time ("still", "right now", "currently", "at the moment") — these are conversational phrasing, not added facts. The identity the Approved Answer already states is NOT a new or added fact when the Candidate repeats it exactly: carrying that same identity through is required preservation, never an addition.
        Ordinary greetings, warm acknowledgements, apologies, and other conversational framing are not factual claims — never let them cause rejection.
        Reject the Candidate only if it changes, drops, or substitutes a DIFFERENT product/variant identity (any code, model, or name the Approved Answer does not state), reverses the availability outcome, makes that outcome uncertain or conditional when the Approved Answer is definite, or introduces any other concrete claim the Approved Answer does not state — a quantity, a warehouse, location, or bin, a price, or a delivery or lead time.
        Judge ONLY these two facts and whether some OTHER concrete claim was added; apply this in any language.
      PROMPT

      GENERATION_INSTRUCTION = <<~PROMPT.strip
        Rephrase the Product Reply below to answer the customer naturally, warmly, and conversationally in the same language and context.
        The Product Reply is your ONLY source of facts. Keep every product name, code, number, price, currency, and unit it contains exactly and unchanged.
        Keep the availability meaning identical — in stock stays in stock, out of stock stays out of stock — but express it in fresh, natural words that fit the customer's latest question, and never state or imply a quantity.
        Do not add, change, infer, or omit any other fact, and introduce nothing the Product Reply does not state.
        Answer the latest request directly and concisely, varying your wording to suit it instead of repeating a fixed sentence, and use earlier messages only when relevant.
        Output only your reply text, with no JSON, markdown, quotes, or explanation.
      PROMPT

      def initialize(account: nil)
        @account = account
      end

      # Returns the accepted, greeting-enforced candidate string, or nil on ANY ineligibility,
      # generation failure, or validation rejection/uncertainty. The returned string is the EXACT
      # enforced text both gates judged, delivered without further transformation. `opening` is the
      # Phase 2 opening/follow-up state and drives the reused Phase 4 greeting policy.
      def call(action:, descriptor:, fallback:, customer_request:, message_history: [], opening: true) # rubocop:disable Metrics/ParameterLists
        # Deterministic eligibility first: an unsupported/malformed descriptor never invokes an LLM.
        return nil unless fact_protection.eligible?(action: action, descriptor: descriptor)

        candidate = sanitized_candidate(generate(fallback, customer_request, message_history, opening))
        return nil if candidate.nil?

        # Phase 4 enforcement runs BEFORE either gate so both validators judge — and the caller
        # delivers — the exact enforced text; a follow-up greeting-only reply enforces to blank.
        enforced = greeting_context.enforce(candidate, opening: opening).presence
        return nil if enforced.blank?

        # Deterministic protected-value/token gate BEFORE the semantic call — a deterministic
        # rejection prevents the semantic LLM call entirely.
        return nil unless fact_protection.accepts?(action: action, descriptor: descriptor, fallback: fallback, candidate: enforced)
        return nil unless validator.valid?(approved_answer: fallback, candidate: enforced, fact_focus: fact_focus_for(descriptor))

        enforced
      rescue StandardError
        nil
      end

      private

      def generate(fallback, customer_request, message_history, opening)
        service = Marine::Llm::BaseService.new(account: @account)
        return nil unless service.configured?

        # schema: REPLY_SCHEMA asks the provider to emit a bare { "reply": <string> } envelope so the
        # natural wording arrives as clean structured output instead of a fenced/prose/markdown blob.
        # temperature 0.0 is variance-reducing ONLY: it minimizes sampling variance so the rephrase is
        # a stabler (not guaranteed byte-identical) restatement of the exact deterministic fallback —
        # it is not a determinism guarantee. The extracted reply remains untrusted and still passes the
        # deterministic ProductFactProtectionValidator and the separate semantic validator.
        result = service.chat(
          messages: messages_with_query(message_history, customer_request),
          system: generation_prompt(fallback, opening),
          temperature: 0.0,
          schema: REPLY_SCHEMA
        )
        return nil unless result[:ok] && result[:message].present?

        reply_from_envelope(result[:message])
      end

      # Parse the provider's { "reply": <string> } generation envelope as an EXACT object — no fence
      # stripping, extraction, or repair. Returns the reply body ONLY for a bare Hash whose sole key
      # is "reply" with a String value; a wrong shape/key/type, an ambiguous duplicate key (rejected
      # by allow_duplicate_key: false), invalid encoding, or any unparseable/passed-through text fails
      # closed to nil so the caller delivers its exact fallback. RubyLLM already collapses top-level
      # duplicate keys on the real structured path, so the duplicate-key guard here is a fail-closed
      # backstop for an unparsed passthrough, not a byte-fidelity claim (the reply is plain prose, not
      # a duplicate-key-sensitive verdict). The returned reply is still untrusted and still passes
      # sanitization, greeting enforcement, and BOTH the deterministic and semantic gates.
      def reply_from_envelope(raw)
        return nil unless raw.is_a?(String) && raw.valid_encoding?

        parsed = JSON.parse(raw, allow_duplicate_key: false)
        return nil unless parsed.is_a?(Hash) && parsed.keys == %w[reply]
        return nil unless parsed['reply'].is_a?(String)

        parsed['reply']
      rescue JSON::ParserError
        nil
      end

      # The greeting policy is delegated to the reused Phase 4 GreetingContext (opening grounds the
      # authoritative business-time greeting; a follow-up carries the no-new-greeting policy), so no
      # greeting directive is hardcoded here.
      def generation_prompt(fallback, opening)
        [GENERATION_INSTRUCTION, greeting_context.interaction_prompt(opening: opening), "Product Reply:\n#{fallback}"].join("\n\n")
      end

      # Smallest generic output-shape gate, run BEFORE either validator: the generation is
      # untrusted, so it must be a valid-encoding String with nonblank substantive content, free
      # of NUL/unsafe control characters, and not a machine-readable payload (a whole fenced
      # block, or a body whose entirety parses as a JSON object/array). Returns the stripped
      # candidate (the exact text both gates judge and the caller delivers), or nil. Ordinary
      # prose that merely contains braces/punctuation passes; nothing is repaired.
      def sanitized_candidate(raw)
        return nil unless raw.is_a?(String) && raw.valid_encoding?

        candidate = raw.strip
        return nil if candidate.blank?
        return nil if raw.match?(UNSAFE_CONTROL_CHARS)
        return nil if candidate.start_with?('```')
        return nil if whole_json_structure?(candidate)

        candidate
      end

      def whole_json_structure?(stripped)
        return false unless ['{', '['].include?(stripped[0])

        parsed = JSON.parse(stripped)
        parsed.is_a?(Hash) || parsed.is_a?(Array)
      rescue JSON::ParserError
        false
      end

      # Mirror the RAG/FAQ path: append the latest request to the bounded history only when it
      # is not already the last message, so it reaches the LLM exactly once.
      def messages_with_query(message_history, customer_request)
        history = Array(message_history)
        last = history.last
        last_content = last && (last[:content] || last['content'])
        return history if last_content.to_s == customer_request.to_s

        history + [{ role: 'user', content: customer_request.to_s }]
      end

      # The binary-stock materiality guidance for a pure stock reply, else nil (unscoped rubric) —
      # the narrow scope that keeps every other product/FAQ semantic judgement unchanged. The
      # descriptor is already an eligibility-checked Hash by the time this runs.
      def fact_focus_for(descriptor)
        STOCK_FACT_FOCUS if STOCK_KINDS.include?(descriptor[:kind])
      end

      def fact_protection = @fact_protection ||= Marine::Catalog::ProductFactProtectionValidator.new

      def greeting_context = @greeting_context ||= Marine::Charge::GreetingContext.new(account: @account)

      def validator = @validator ||= Marine::Charge::FactPreservationValidator.new(account: @account)
    end
  end
end
