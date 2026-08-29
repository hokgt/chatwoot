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
        Answer the customer's latest message the way a warm, helpful human colleague would speak — naturally and conversationally, in everyday idiomatic phrasing that fits exactly what they just asked.
        Write your ENTIRE reply in the SAME language as the customer's latest message, and never switch to another language — the Product Reply is only an internal source of facts, not the wording to send.
        The Product Reply is your ONLY source of facts. Keep every product name, code, number, price, currency, and unit it contains exactly and unchanged, but do NOT translate, echo, or reuse its sentence structure — state those facts freshly in your own words, as if answering the customer for the first time.
        Keep the availability meaning identical — in stock stays in stock, out of stock stays out of stock — but express it in fresh, natural words that fit the customer's latest question, and never state or imply a quantity.
        Do not add, change, infer, or omit any other fact, and introduce nothing the Product Reply does not state.
        Answer the latest request directly and concisely, varying your wording to suit it instead of repeating a fixed sentence, and use earlier messages only when relevant.
        Output only your reply text, with no JSON, markdown, quotes, or explanation.
      PROMPT

      # Appended ONLY to the generation prompt of a pure stock reply (see #generation_prompt). A bare
      # availability restatement ("<code> is in stock") is the model's lowest-effort answer and reads as a
      # stiff template; the two gates cannot see tone, so this is the lever that makes the ACCEPTED wording
      # genuinely human. It mandates real chat framing (a warm opener, the answer in the model's own words,
      # a short friendly offer to help) so the reply is not a one-clause fact restatement — while forbidding
      # any NEW fact, so the deterministic and semantic gates still hold. It is generic: no language, no
      # phrase list, no per-language example. The exact codes/numbers are still kept verbatim (base
      # instruction) and every safety gate still runs on the result.
      STOCK_WARMTH_INSTRUCTION = <<~PROMPT.strip
        Reply like a real, friendly human colleague chatting with the customer, and match how casually or formally they wrote to you.
        Write it as a genuine chat message, not a one-line restatement of the fact: open with a brief, warm human acknowledgement, then give the answer in your OWN fresh words, then add a short friendly offer to help further.
        Say whether the item is available in your own relaxed, everyday way — the way you would actually tell a friend — rather than the most formal, dictionary-literal phrasing; keep the in-stock / out-of-stock meaning exactly.
        Add NO new fact of any kind — no quantity, price, location, delivery, or lead time — and change none of the facts you were given; the warmth must come only from tone and conversational framing, never from new information.
      PROMPT

      # Appended ONLY to a bounded stock-reply regeneration (see #call): the first candidate was a bare
      # restatement of the fact with almost no conversational framing, so this asks for a warmer, genuinely
      # human answer. It names no language, phrase, or example — a generic tone nudge, paired with the small
      # nonzero stock temperature so the retry actually resamples.
      REGENERATION_NUDGE = <<~PROMPT.strip
        Your previous reply was too close to a bare restatement of the fact. Answer the customer again, warmer and more genuinely conversational, adding real human framing (a friendly acknowledgement and a short offer to help) around the same unchanged facts — without introducing any new fact.
      PROMPT

      # A pure stock reply is generated at a SMALL bounded nonzero temperature (not greedy 0.0) so the
      # human framing has room to vary instead of collapsing onto the same terse restatement, AND so the
      # single bounded regeneration below actually resamples. It never relaxes acceptance: the candidate
      # still passes the bare-restatement check, greeting enforcement, the deterministic
      # ProductFactProtectionValidator, the language gate, and the separate semantic validator. Every other
      # (non-stock) reply keeps greedy 0.0 unchanged.
      STOCK_TEMPERATURE = 0.6

      # At most one regeneration for a stock reply whose first candidate is a bare restatement of the
      # fallback: one initial attempt plus one retry. If the retry is still bare, the service fails closed
      # to nil (the caller delivers its exact deterministic fallback) rather than looping unboundedly.
      MAX_STOCK_ATTEMPTS = 2

      # The fallback's fact-stripped skeleton must be at least this many words for the bare-restatement
      # check to fire; a shorter skeleton cannot be told apart from unavoidable keywords, so it stays off.
      MIN_SKELETON_TOKENS = 3

      # A candidate that REPRODUCES the fallback's whole fact-stripped skeleton counts as genuinely framed
      # (not a bare restatement) only when it adds at least this many words of its OWN beyond that skeleton —
      # i.e. real conversational content, not just a greeting-plus-affirmation wrapper. Below it, the reply
      # is essentially the fallback restated and is regenerated for warmth.
      MIN_ADDED_CONTENT = 4

      # Generic fact-token classes (currency symbol, any alnum run containing a digit, an uppercase code)
      # removed from BOTH texts before comparing sentence skeletons, so the bare-restatement check compares
      # STRUCTURE only — never the shared codes/numbers both texts must legitimately carry. Mirrors the
      # token classes the deterministic ProductFactProtectionValidator already protects.
      FACT_TOKEN = /\p{Sc}|[[:alnum:]]*\d[[:alnum:]]*|[A-Z]{2,}/

      # Bounded, allowlisted reply-language FORMAT (a format allowlist, not a language list):
      # a 2–3 letter primary subtag with an optional single subtag. Mirrors ReplyLocalizer's
      # pattern so the authoritative provider/customer language a caller threads in is validated
      # identically before it drives the deterministic language-consistency gate.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      def initialize(account: nil)
        @account = account
      end

      # Returns the accepted, greeting-enforced candidate string, or nil on ANY ineligibility,
      # generation failure, or validation rejection/uncertainty. The returned string is the EXACT
      # enforced text both gates judged, delivered without further transformation. `opening` is the
      # Phase 2 opening/follow-up state and drives the reused Phase 4 greeting policy.
      #
      # `reply_language` is the authoritative customer/reply language the caller resolved from the
      # SAME customer turn (the provider classification the localizer already read). When it is a
      # known, well-formed code, the accepted candidate must be PROVABLY in THAT language: only a
      # candidate the shared detector RELIABLY reads with the same primary subtag passes; a candidate
      # read as a different primary language, AND a candidate whose language cannot be read reliably,
      # are both rejected (the caller then supplies a same-language fallback). This fails CLOSED under
      # a known target — an unreliable read never silently accepts a possibly-wrong-language candidate
      # — so no wrong-language rephrase (e.g. an English reply to an Indonesian customer) can pass.
      # Only when the target is absent/unknown/malformed does the gate not fire (no authoritative
      # language to bind to, backward-compatible). Language binding is generic (a detector + a code),
      # with no per-language phrase list. The reply-language signal also makes the reused greeting
      # policy target-aware, so an opening turn never grounds or leaves an Indonesian greeting on a
      # reply written in a known non-Indonesian language.
      def call(action:, descriptor:, fallback:, customer_request:, message_history: [], opening: true, reply_language: nil) # rubocop:disable Metrics/ParameterLists,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity -- a flat sequence of fail-closed delivery gates
        # Deterministic eligibility first: an unsupported/malformed descriptor never invokes an LLM.
        return nil unless fact_protection.eligible?(action: action, descriptor: descriptor)

        # A pure stock reply gets a small nonzero temperature and, if the first candidate is a bare
        # restatement of the deterministic fallback, exactly ONE bounded regeneration for warmth (see
        # #merely_restates?). Every other reply keeps the single greedy-temperature generation.
        stock = STOCK_KINDS.include?(descriptor[:kind])
        attempt = 0
        nudge = nil
        loop do
          attempt += 1
          candidate = sanitized_candidate(generate(fallback, customer_request, message_history, opening, reply_language, stock: stock, nudge: nudge))
          return nil if candidate.nil?

          # Phase 4 enforcement runs BEFORE either gate so both validators judge — and the caller
          # delivers — the exact enforced text; a follow-up greeting-only reply enforces to blank. The
          # reply_language keeps enforcement target-aware (an Indonesian opening greeting is stripped
          # from a known non-Indonesian reply rather than normalized onto it).
          enforced = greeting_context.enforce(candidate, opening: opening, reply_language: reply_language).presence
          return nil if enforced.blank?

          # Bare-restatement guard (stock only), BEFORE any gate: a candidate that reproduces the whole
          # fallback fact-skeleton with almost no conversational framing is a stiff template, not a
          # naturalization. Regenerate once for warmth; if the retry is still bare, fail closed to nil so
          # the caller delivers its exact deterministic fallback rather than looping. Runs before the
          # semantic call so a bare reply never spends it. A genuinely warm reply that happens to keep the
          # faithful availability phrase (with real added framing) is NOT bare and passes straight through.
          if stock && merely_restates?(enforced, fallback)
            return nil if attempt >= MAX_STOCK_ATTEMPTS

            nudge = REGENERATION_NUDGE
            next
          end

          # Deterministic protected-value/token gate BEFORE the semantic call — a deterministic
          # rejection prevents the semantic LLM call entirely.
          return nil unless fact_protection.accepts?(action: action, descriptor: descriptor, fallback: fallback, candidate: enforced)
          # Deterministic language-consistency gate, also BEFORE the semantic call: a wrong-language
          # candidate is rejected without spending the semantic LLM call.
          return nil unless language_consistent?(enforced, reply_language)
          return nil unless validator.valid?(approved_answer: fallback, candidate: enforced, fact_focus: fact_focus_for(descriptor))

          return enforced
        end
      rescue StandardError
        nil
      end

      private

      def generate(fallback, customer_request, message_history, opening, reply_language, stock: false, nudge: nil) # rubocop:disable Metrics/ParameterLists -- a flat generation call
        service = Marine::Llm::BaseService.new(account: @account)
        return nil unless service.configured?

        # schema: REPLY_SCHEMA asks the provider to emit a bare { "reply": <string> } envelope so the
        # natural wording arrives as clean structured output instead of a fenced/prose/markdown blob.
        # temperature: a pure stock reply uses a small bounded nonzero STOCK_TEMPERATURE (so the rephrase
        # can be idiomatic instead of a verbatim same-language echo, and the bounded regeneration varies);
        # every other reply keeps greedy 0.0. Either way the extracted reply is untrusted and still passes
        # the bare-restatement check, greeting enforcement, the deterministic ProductFactProtectionValidator,
        # the language gate, and the separate semantic validator.
        result = service.chat(
          messages: messages_with_query(message_history, customer_request),
          system: generation_prompt(fallback, opening, reply_language, stock: stock, nudge: nudge),
          temperature: stock ? STOCK_TEMPERATURE : 0.0,
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
      # The stock-only warmth mandate is appended for a stock reply so the ACCEPTED wording is genuinely
      # human, not a terse fact restatement (the gates cannot judge tone). Every other reply keeps the base
      # instruction unchanged. A bounded regeneration nudge, when present, follows.
      def generation_prompt(fallback, opening, reply_language, stock: false, nudge: nil)
        [GENERATION_INSTRUCTION, (STOCK_WARMTH_INSTRUCTION if stock),
         greeting_context.interaction_prompt(opening: opening, reply_language: reply_language),
         nudge, "Product Reply:\n#{fallback}"].compact.join("\n\n")
      end

      # True when the candidate is a BARE restatement of the fallback: it reproduces the fallback's whole
      # fact-stripped skeleton (>= MIN_SKELETON_TOKENS words) yet adds fewer than MIN_ADDED_CONTENT words of
      # its own — a stiff template with at most a greeting-plus-affirmation wrapper, the tone the customer
      # rejected. Language-agnostic: it strips the shared fact tokens (codes/numbers/currency) from BOTH
      # texts and compares lowercase letter-word sets. A candidate that REWORDS the availability (dropping
      # part of the skeleton) or wraps it in REAL conversational framing (a genuine offer/acknowledgement,
      # several added words) is NOT bare and passes straight through — so a warm reply that keeps the
      # faithful availability phrase is accepted. No phrase/language list; the facts themselves are guarded
      # by the two gates.
      def merely_restates?(candidate, fallback)
        skeleton = skeleton_words(fallback).uniq
        return false if skeleton.length < MIN_SKELETON_TOKENS

        candidate_words = skeleton_words(candidate)
        return false unless (skeleton - candidate_words).empty? # the whole fact-skeleton is reproduced

        added = candidate_words.reject { |word| skeleton.include?(word) }
        added.length < MIN_ADDED_CONTENT
      end

      def skeleton_words(text)
        text.gsub(FACT_TOKEN, ' ').downcase.scan(/[[:alpha:]]+/)
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

      # True ONLY when the candidate is PROVABLY in the authoritative reply/customer language. When
      # `reply_language` is a known, well-formed code (the provider classification of the same customer
      # turn), the candidate passes only if the shared detector RELIABLY reads it with the SAME primary
      # subtag; a reliably-different read AND an unreliable/unreadable read both FAIL CLOSED (false), so
      # under a known target no possibly-wrong-language candidate is ever silently accepted (the caller
      # then supplies a same-language fallback). Only an absent/unknown/malformed target fails open
      # (true) — there is no authoritative language to bind to, so faithful wording is not second-guessed
      # (backward-compatible). Compared at the PRIMARY subtag so a regional variant (e.g. zh-latn vs zh)
      # still matches. Reuses Marine::Llm::LanguageDetector — no phrase list.
      def language_consistent?(candidate, reply_language)
        target = normalize_language(reply_language)
        return true if target.nil?

        candidate_language = reliable_language(candidate)
        return false if candidate_language.nil?

        primary_subtag(candidate_language) == primary_subtag(target)
      end

      # The candidate's detected language ONLY when the detector is reliable about it, else nil. A
      # full reply sentence classifies reliably where a short customer turn would not, so binding the
      # target to the provider signal (not a re-detection of the short turn) avoids CLD3 misreads.
      def reliable_language(text)
        result = Marine::Llm::LanguageDetector.new(text).detect
        return nil unless result[:reliable]

        code = result[:language].to_s.strip.downcase
        code.empty? || code == 'unknown' ? nil : code
      end

      # Bounded, allowlisted language code, or nil for a missing/malformed/unknown value.
      def normalize_language(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        return nil if code.empty? || code == 'unknown'

        code if code.match?(LANGUAGE_PATTERN)
      end

      def primary_subtag(code) = code.split('-').first

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
