# Source-less Product Catalog PREVIEW for the Marine Assistant Playground.
#
# The Playground drives Marine::Agent::Runner with conversation: nil, so the trigger-bound
# product orchestration (which is gated on a persisted Conversation) never runs and a valid
# catalog request would fall through to general RAG and be answered "unavailable". This service
# closes that gap by running the SAME deterministic Marine::Catalog::ProductQueryOrchestrator the
# real conversation path uses, then rendering its plan into the exact same deterministic text via
# the shared Marine::Catalog::ReplyPresenter — so the Playground faithfully previews supported
# catalog behavior.
#
# It is strictly READ-ONLY and NON-DELIVERING:
#   * multi-turn product state (validated family/variant, clarification kind+count, catalog-already-
#     sent) is carried in an opaque SIGNED, account/assistant-scoped, expiring token
#     (Marine::Catalog::PlaygroundStateToken) round-tripped through the browser — NEVER persisted to
#     any DB/Redis/session. The prior token is verified, the plan's deterministic state operation is
#     applied to an IN-MEMORY ProductFlowStateStore snapshot (reusing the exact allowlisting and
#     lifecycle semantics), and the next signed snapshot is returned. A tampered/expired/foreign
#     token fails closed to a fresh flow;
#   * a DIRECT catalog request whose primary catalog exists is previewed with a TRUTHFUL "would be
#     shared" line plus a read-only, allowlisted metadata card (family, safe filename, MIME, byte
#     size) — it NEVER creates or delivers a native catalog attachment and exposes no blob/download
#     URL;
#   * a product handoff shows the factless, request-aware acknowledgement (the exact message a
#     customer would see) WITHOUT any assignment/handoff mutation;
#   * a KNOWN catalog outage fails CLOSED to the safe handoff acknowledgement — it NEVER falls
#     through to RAG (which has no catalog knowledge and would fabricate an answer);
#   * no Conversation, Message, Attachment, job, ERP call, or persisted state write ever happens.
#
# It returns a reply payload shaped like the RAG reply the Playground controller already renders
# (`response`/`action`/`agent_name`), enriched with an optional read-only `catalog_preview` card and
# the next `state_token`; or nil to fall through to the unchanged RAG path for a non-product turn, a
# blank query, or an unexpected (non-catalog) failure (fail-safe: no worse than the prior behavior).
module Marine
  module Catalog
    # rubocop:disable Metrics/ClassLength -- the preview is a single cohesive read-only delivery
    # adapter (state decode/apply, catalog card, and now the shared-composer stock path) whose parts
    # only make sense together; splitting it would scatter the source-less preview contract.
    class PlaygroundPreview
      LOG_PREFIX = '[Marine::Catalog::PlaygroundPreview]'.freeze
      SOURCE_TYPE = 'marine_product'.freeze
      ORCHESTRATION_PATH = 'product'.freeze

      # Defense-in-depth history bounds, mirroring the controller's allowlist and the canonical
      # ContextBuilder window: the transcript is untrusted client input, so it is re-bounded here
      # even though the controller already bounded it (a direct-unit caller may not have).
      MAX_HISTORY_TURNS = 10
      MAX_TURN_CHARS = 500
      HISTORY_ROLES = %w[user assistant].freeze

      def initialize(assistant:, account:)
        @assistant = assistant
        @account = account
      end

      def call(query:, history: [], state_token: nil, knowledge_available: false)
        return nil if query.blank?

        bounded = bounded_history(history)
        prior = decode_state(state_token)
        plan = orchestrator.process(text: query.to_s, context: bounded,
                                    flow: store.snapshot_for_planning(prior) || {}, suppressed: false,
                                    knowledge_available: knowledge_available)
        return nil if plan[:action] == :not_product

        log_event('preview.plan', action: plan[:action], language: plan[:language])
        payload = build_payload(plan, query, bounded, prior)
        log_event('preview.reply', action: plan[:action])
        payload
      rescue Marine::Catalog::Errors::CatalogError => e
        # KNOWN catalog outage. The orchestrator already fails closed to a safe factless handoff
        # plan, so this fires only when catalog reasoning raises outside it (e.g. the read-only
        # document selection). It must NEVER fall through to RAG (that would let general RAG
        # fabricate a catalog answer): render the safe fail-closed handoff acknowledgement instead.
        log_event('preview.catalog_error', error_class: e.class.name)
        catalog_unavailable_payload(query, bounded, decode_state(state_token))
      rescue StandardError => e
        capture(e)
        log_event('preview.error', error_class: e.class.name)
        nil
      end

      private

      attr_reader :assistant, :account

      # Untrusted transcript re-bounded/allowlisted: only user/assistant roles, blank content
      # dropped, each turn truncated, newest turns kept (oldest-to-newest order preserved).
      def bounded_history(history)
        Array(history).filter_map do |turn|
          role = (turn[:role] || turn['role']).to_s
          content = (turn[:content] || turn['content']).to_s.strip
          next if content.blank? || HISTORY_ROLES.exclude?(role)

          { role: role, content: content[0, MAX_TURN_CHARS] }
        end.last(MAX_HISTORY_TURNS)
      end

      # Verify the client-supplied token and re-normalize its snapshot through the store's trust
      # boundary. A blank/tampered/expired/foreign token yields nil (a fresh flow) — fail closed.
      def decode_state(token)
        return nil if token.blank?

        store.normalize_snapshot(state_token.decode(token))
      end

      def build_payload(plan, query, history, prior)
        snapshot = apply_state(plan, prior)
        return stock_payload(plan, query, history, snapshot) if stock_reply?(plan)

        english, catalog_card, next_snapshot = render(plan, snapshot)
        text = localize(english: english, protection: localization_protection(plan),
                        language: plan[:language], query: query, history: history)
        reply_payload(text, next_state: next_snapshot, catalog: catalog_card)
      end

      # A pure stock reply is resolved through the shared Marine::Catalog::StockReplyComposer — the
      # SAME dynamic response boundary the real conversation (ResponseBuilderJob) consumes — so the
      # source-less preview reaches the IDENTICAL DELIVER/HANDOFF business conclusion for the same
      # account/assistant/context/catalog/language state. It never claims availability where a real
      # conversation would hand off (the reported inconsistency), nor the reverse.
      def stock_reply?(plan)
        plan[:action] == :reply &&
          Marine::Catalog::StockReplyComposer::STOCK_KINDS.include?(plan.dig(:reply, :kind))
      end

      # DELIVER -> the composer's accepted DYNAMIC in-language stock candidate (never the deterministic
      # grounding fallback, which stays internal). HANDOFF -> the factless acknowledgement the customer
      # would see (the composer's in-language acknowledgement when provable, else its localized fallback
      # acknowledgement) — the same safe business outcome the real conversation reaches (a factless
      # transfer, NOT a stock claim), rendered preview-only with NO assignment/handoff/persistence
      # mutation, just via the preview delivery adapter. It never disguises a handoff as a stock reply.
      def stock_payload(plan, query, history, snapshot)
        descriptor = plan[:reply]
        fallback = localize(english: presenter.reply_text(plan), protection: [plan[:action], descriptor],
                            language: plan[:language], query: query, history: history)
        decision = stock_composer.compose(
          descriptor: descriptor, fallback: fallback, reply_language: plan[:language],
          customer_request: query.to_s, message_history: history, opening: opening?(history),
          localized_ack: lambda {
            localize(english: presenter.handoff_ack_text(nil), protection: [nil, nil],
                     language: plan[:language], query: query, history: history)
          }
        )
        return reply_payload(decision.text, next_state: snapshot) if decision.deliver?

        reply_payload(decision.message || decision.ack, next_state: snapshot)
      end

      # Opening (vs follow-up) for the reused greeting policy: no prior assistant turn in the bounded
      # history mirrors the conversation's "Marine has not yet replied in this window". Wording only —
      # it never affects the DELIVER/HANDOFF business decision.
      def opening?(history)
        Array(history).none? { |turn| (turn[:role] || turn['role']).to_s == 'assistant' }
      end

      def stock_composer
        @stock_composer ||= Marine::Catalog::StockReplyComposer.new(account: account)
      end

      # Apply the plan's deterministic state operation to the prior IN-MEMORY snapshot — the exact
      # ProductFlowStateStore start!/update! semantics, minus any persistence.
      def apply_state(plan, prior)
        state = plan[:state] || {}
        store.apply_snapshot(prior, operation: state[:operation] || :none, changes: state[:changes] || {})
      end

      # Deterministic English text + optional read-only catalog card + the next snapshot for the
      # plan, reusing the shared presenter so the wording is identical to a real conversation. A
      # send_catalog turn is previewed WITHOUT delivering an attachment; a product handoff shows the
      # factless, request-aware acknowledgement; every other action renders its deterministic reply.
      def render(plan, snapshot)
        case plan[:action]
        when :send_catalog then render_send_catalog(plan, snapshot)
        when :handoff then [presenter.handoff_ack_text(plan[:handoff_category]), nil, snapshot]
        else [presenter.reply_text(plan), nil, snapshot]
        end
      end

      # DIRECT catalog request: when a usable primary catalog exists for the validated family and
      # none has been previewed this flow, render the TRUTHFUL "would be shared" line, attach a
      # read-only metadata card, and mark catalog_sent in the returned snapshot (the exact
      # one-catalog-per-flow marker the real delivery sets) so a follow-up is recognized as already
      # previewed — not a re-offer, and never a second card. A REPEATED request whose card was
      # already shown gets the Playground-truthful "preview already shown" line (NOT the real path's
      # "already shared the catalog" wording — the preview delivered no file); a request with no
      # usable catalog gets the honest no-catalog line. A catalog-ASSISTED send_catalog (reply nil)
      # renders its deterministic variant clarification, no card.
      def render_send_catalog(plan, snapshot)
        return [presenter.reply_text(plan), nil, snapshot] unless presenter.direct_catalog_request?(plan)

        descriptor = plan[:reply] || {}
        document = catalog_document(plan.dig(:reply, :family_code))
        already_sent = catalog_already_sent?(snapshot)
        if document && already_sent
          [presenter.catalog_preview_already_shown_text(descriptor), nil, snapshot]
        elsif document
          card = catalog_metadata(plan, document)
          next_snapshot = store.apply_snapshot(snapshot, operation: :update, changes: catalog_sent_changes(document))
          [presenter.catalog_preview_available_text(descriptor), card, next_snapshot]
        else
          [presenter.direct_catalog_fallback_text(descriptor, already_sent: false), nil, snapshot]
        end
      end

      # Read-only, allowlisted catalog metadata for the preview card — family display plus the safe
      # file metadata the canonical document serializer already authorizes (filename, MIME, byte
      # size). No blob key, no download/delivery URL, no content.
      def catalog_metadata(plan, document)
        file = Marine::Documents::Serializer.file_metadata(document)
        return nil if file.nil?

        {
          'family_name' => presenter.catalog_family_name(plan[:reply] || {}),
          'filename' => file['filename'],
          'content_type' => file['content_type'],
          'byte_size' => file['byte_size']
        }
      end

      # The one-catalog-per-flow marker the real delivery records after creating the Message; here
      # there is no Message, so only the flow-level markers are set on the in-memory snapshot.
      def catalog_sent_changes(document)
        { 'catalog_sent' => true, 'catalog_document_id' => document.id }
      end

      def catalog_already_sent?(snapshot)
        snapshot.is_a?(Hash) && snapshot['catalog_sent'] == true
      end

      # Read-only primary-catalog selection. A catalog repository/storage failure must fail CLOSED,
      # never fall through to RAG as a fabricated answer: surface it as the canonical
      # catalog-unavailable error so #call renders the safe handoff acknowledgement.
      def catalog_document(family_code)
        Marine::Documents::ProductCatalogSelector.new(
          account: account, assistant: assistant, family_code: family_code
        ).call
      rescue Marine::Catalog::Errors::CatalogError
        raise
      rescue StandardError => e
        log_event('preview.catalog_lookup_error', error_class: e.class.name)
        raise Marine::Catalog::Errors::CatalogUnavailableError
      end

      # Fail-closed catalog-unavailable preview: the safe, factless handoff acknowledgement (never a
      # fabricated catalog answer, never a fall-through to RAG). Carries the prior state forward
      # unchanged (no state operation happened).
      def catalog_unavailable_payload(query, history, prior)
        text = localize(english: presenter.handoff_ack_text(nil), protection: [nil, nil],
                        language: nil, query: query, history: history)
        reply_payload(text, next_state: prior)
      end

      # The handoff acknowledgement is factless (not a descriptor's text), so it localizes with no
      # protected descriptor — exactly as the conversation path does. Every other action carries its
      # descriptor so protected display values (family/variant/price) stay literal in translation.
      def localization_protection(plan)
        return [nil, nil] if plan[:action] == :handoff

        [plan[:action], plan[:reply]]
      end

      # Delivery-only localization to the customer's language via the canonical ReplyLocalizer
      # (source-less: no conversation needed). It fails closed to English internally, and never
      # changes the catalog DECISION — only the wording follows the customer's latest turn.
      def localize(english:, protection:, language:, query:, history:)
        action, descriptor = protection
        Marine::Catalog::ReplyLocalizer.new(
          text: english,
          trigger_text: query.to_s,
          context: history_contents(history),
          provider_language: language,
          fallback_language: configured_reply_language,
          account: account,
          action: action,
          descriptor: descriptor
        ).call
      end

      # Bounded prior turn contents (newest first) — a fallback language signal only, mirroring the
      # conversation path's customer_language_context.
      def history_contents(history)
        Array(history).reverse.filter_map { |item| (item[:content] || item['content']).presence }
      end

      def configured_reply_language
        assistant.config.to_h['language'] if assistant.respond_to?(:config)
      end

      def reply_payload(text, next_state: nil, catalog: nil)
        {
          'response' => text,
          'action' => 'reply',
          'agent_name' => (assistant.name if assistant.respond_to?(:name)),
          'source_type' => SOURCE_TYPE,
          'orchestration_path' => ORCHESTRATION_PATH,
          'state_token' => state_token.encode(next_state),
          'catalog_preview' => catalog
        }.compact
      end

      def orchestrator
        @orchestrator ||= Marine::Catalog::ProductQueryOrchestrator.new(
          intent_extractor: Marine::Catalog::IntentExtractor.new(account: account)
        )
      end

      def presenter
        @presenter ||= Marine::Catalog::ReplyPresenter.new
      end

      # A conversation-less store used ONLY for its pure in-memory snapshot transforms
      # (normalize/plan/apply) — never a persisted mutation, so the preview writes no state.
      def store
        @store ||= Marine::Catalog::ProductFlowStateStore.new(conversation: nil)
      end

      def state_token
        @state_token ||= Marine::Catalog::PlaygroundStateToken.new(account: account, assistant: assistant)
      end

      def capture(error)
        return if account.nil?

        ChatwootExceptionTracker.new(error, account: account).capture_exception
      end

      # Structured, secret-free single-line logging — only action and a bounded language code; never
      # the token or any state.
      def log_event(event, **fields)
        parts = fields.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
        Rails.logger.info("#{LOG_PREFIX} event=#{event} #{parts}".strip)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
