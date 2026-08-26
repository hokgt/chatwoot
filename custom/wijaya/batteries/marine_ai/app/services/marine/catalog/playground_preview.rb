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
#   * an EMPTY flow snapshot is used (no ProductFlowStateStore, no persisted state) — the preview
#     is stateless per turn; the bounded multi-turn HISTORY still feeds intent extraction as
#     context, exactly like a real turn;
#   * a send_catalog turn is previewed with a caption or an honest no-catalog line decided by the
#     read-only ProductCatalogSelector — it NEVER creates or delivers a native catalog attachment;
#   * a product handoff shows the factless, request-aware acknowledgement (the exact message a
#     customer would see) WITHOUT any assignment/handoff mutation;
#   * no Conversation, Message, Attachment, job, ERP call, or state write ever happens here.
#
# It returns a reply payload shaped like the RAG reply the Playground controller already renders
# (`response`/`action`/`agent_name`), or nil to fall through to the unchanged RAG path for a
# non-product turn, a blank query, or any failure (fail-safe: no worse than the prior behavior).
module Marine
  module Catalog
    class PlaygroundPreview
      LOG_PREFIX = '[Marine::Catalog::PlaygroundPreview]'.freeze
      SOURCE_TYPE = 'marine_product'.freeze
      ORCHESTRATION_PATH = 'product'.freeze

      def initialize(assistant:, account:)
        @assistant = assistant
        @account = account
      end

      def call(query:, history: [])
        return nil if query.blank?

        plan = orchestrator.process(text: query.to_s, context: Array(history), flow: {}, suppressed: false)
        return nil if plan[:action] == :not_product

        log_event('preview.plan', action: plan[:action], language: plan[:language])
        payload = build_payload(plan, query, history)
        log_event('preview.reply', action: plan[:action])
        payload
      rescue Marine::Catalog::Errors::CatalogError => e
        # Catalog unreachable/unconfigured: a source-less preview cannot faithfully answer a
        # product turn, so fall through to RAG rather than fabricating a catalog fact.
        log_event('preview.catalog_error', error_class: e.class.name)
        nil
      rescue StandardError => e
        capture(e)
        log_event('preview.error', error_class: e.class.name)
        nil
      end

      private

      attr_reader :assistant, :account

      def build_payload(plan, query, history)
        english = deterministic_text(plan)
        reply_payload(localize(english, plan, query, history))
      end

      # Deterministic English text for the plan, reusing the shared presenter so the wording is
      # identical to a real conversation. A send_catalog turn is previewed WITHOUT delivering an
      # attachment (caption vs honest no-catalog line); a product handoff shows the factless,
      # request-aware acknowledgement; every other action renders its deterministic reply text.
      def deterministic_text(plan)
        case plan[:action]
        when :send_catalog then catalog_preview_text(plan)
        when :handoff then presenter.handoff_ack_text(plan[:handoff_category])
        else presenter.reply_text(plan)
        end
      end

      # DIRECT catalog request: preview the caption when a usable primary catalog exists for the
      # validated family, else the honest no-catalog line (never "already sent" — the preview holds
      # no persisted flow). A catalog-ASSISTED send_catalog (reply nil) renders its deterministic
      # variant clarification via the presenter.
      def catalog_preview_text(plan)
        return presenter.reply_text(plan) unless presenter.direct_catalog_request?(plan)
        return presenter.reply_text(plan) if catalog_document(plan.dig(:reply, :family_code))

        presenter.direct_catalog_fallback_text(plan[:reply] || {}, already_sent: false)
      end

      def catalog_document(family_code)
        Marine::Documents::ProductCatalogSelector.new(
          account: account, assistant: assistant, family_code: family_code
        ).call
      end

      # Delivery-only localization to the customer's language via the canonical ReplyLocalizer
      # (source-less: no conversation needed). It fails closed to English internally, and never
      # changes the catalog DECISION — only the wording follows the customer's latest turn.
      def localize(english, plan, query, history)
        action, descriptor = localization_protection(plan)
        Marine::Catalog::ReplyLocalizer.new(
          text: english,
          trigger_text: query.to_s,
          context: history_contents(history),
          provider_language: plan[:language],
          fallback_language: configured_reply_language,
          account: account,
          action: action,
          descriptor: descriptor
        ).call
      end

      # The handoff acknowledgement is factless (not the descriptor's text), so it localizes with
      # no protected descriptor — exactly as the conversation path does. Every other action carries
      # its descriptor so protected display values (family/variant/price) stay literal in translation.
      def localization_protection(plan)
        return [nil, nil] if plan[:action] == :handoff

        [plan[:action], plan[:reply]]
      end

      # Bounded prior turn contents (newest first) — a fallback language signal only, mirroring the
      # conversation path's customer_language_context.
      def history_contents(history)
        Array(history).reverse.filter_map { |item| (item[:content] || item['content']).presence }
      end

      def configured_reply_language
        assistant.config.to_h['language'] if assistant.respond_to?(:config)
      end

      def reply_payload(text)
        {
          'response' => text,
          'action' => 'reply',
          'agent_name' => (assistant.name if assistant.respond_to?(:name)),
          'source_type' => SOURCE_TYPE,
          'orchestration_path' => ORCHESTRATION_PATH
        }
      end

      def orchestrator
        @orchestrator ||= Marine::Catalog::ProductQueryOrchestrator.new(
          intent_extractor: Marine::Catalog::IntentExtractor.new(account: account)
        )
      end

      def presenter
        @presenter ||= Marine::Catalog::ReplyPresenter.new
      end

      def capture(error)
        return if account.nil?

        ChatwootExceptionTracker.new(error, account: account).capture_exception
      end

      # Structured, secret-free single-line logging — only action and a bounded language code.
      def log_event(event, **fields)
        parts = fields.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
        Rails.logger.info("#{LOG_PREFIX} event=#{event} #{parts}".strip)
      end
    end
  end
end
