# Deterministic, fact-safe customer-facing TEXT for a product-decision plan.
#
# This is a PURE, side-effect-free presenter: it never touches a database, provider,
# I18n, Message, Attachment, or state. It turns a ProductQueryOrchestrator plan (and its
# frozen ReplyRenderer descriptor) into the exact deterministic ENGLISH string a later
# delivery phase localizes — the single source of truth for that wording, shared by the
# trigger-bound ResponseBuilderJob (real conversations) and the source-less
# Marine::Catalog::PlaygroundPreview so the two never drift. It deliberately produces no
# localized/natural prose and reads no flow/document itself: the caller supplies the
# already-decided catalog booleans. Every template maps an allowlisted descriptor :kind
# to a fixed or field-interpolated line and never emits a raw stock quantity, warehouse
# detail, SQL, error, or any price field beyond the three approved display values.
module Marine
  module Catalog
    class ReplyPresenter
      # Fixed, fact-safe templates for descriptor kinds that carry no interpolated field. The two
      # stock entries double as the product-agnostic fallback when a stock descriptor carries no
      # usable validated code (see #stock_text); a code-bearing stock descriptor names that code.
      STATIC_PRODUCT_TEXT = {
        price_unavailable: "I'm sorry, I don't have the price for that item right now.",
        stock_available: 'Good news — that item is currently in stock.',
        stock_empty: "I'm sorry, that item is currently out of stock."
      }.freeze

      GENERIC_PRODUCT_TEXT = 'Could you share a little more detail about the product you need?'.freeze

      # Deterministic, factless, unbranded acknowledgement for a product-flow handoff — the safe
      # localized fallback the natural-wording layer rephrases in context. It asserts nothing and
      # names no company, so it never turns a customer-supplied destination or quantity into a claim.
      HANDOFF_ACK_TEXT = "I'm sorry, I'm not able to confirm that for you directly. Let me bring in a colleague who can help you with this.".freeze

      # Request-category-aware factless acknowledgements, keyed by the bounded generic
      # unsupported-request category. Each states only an INABILITY to confirm the request type and a
      # human follow-up — never an answer, a promise, or a customer/destination/price value. The
      # delivery-feasibility line may refer to "the location you mentioned" generically but asserts no
      # destination and no coverage. An unknown/"other"/missing category is not listed here and falls
      # closed to the fully generic HANDOFF_ACK_TEXT.
      HANDOFF_ACK_BY_CATEGORY = {
        'delivery_feasibility' => "I'm sorry, I can't confirm delivery to the location you mentioned. Let me bring in a colleague to help with this.",
        'shipping_cost' => "I'm sorry, I can't confirm the shipping cost for you directly. Let me bring in a colleague to help with this.",
        'warehouse_location' => "I'm sorry, I can't confirm our location details for you directly. Let me bring in a colleague to help with this.",
        'exact_quantity' => "I'm sorry, I can't confirm the exact quantity available for you directly. Let me bring in a colleague to help with this."
      }.freeze

      # Renders the caption/text for a plan. A DIRECT catalog request carries a :catalog reply
      # descriptor and renders a catalog caption; a catalog-ASSISTED send_catalog (reply nil)
      # renders the deterministic variant clarification, used both as its no-usable-catalog text
      # fallback and as the caption accompanying the native catalog attachment (Phase 6) so the
      # customer can continue with an exact code; every other product reply maps its frozen
      # descriptor kind to a fixed or field-interpolated, fact-safe template.
      def reply_text(plan)
        descriptor = plan[:reply] || {}
        return composite_text(descriptor) if descriptor[:kind] == :composite

        dynamic = dynamic_product_text(descriptor)
        return dynamic if dynamic
        return clarify_variant_text(Array(plan.dig(:state, :changes, 'expected_attributes'))) if plan[:action] == :send_catalog

        STATIC_PRODUCT_TEXT[descriptor[:kind]] || GENERIC_PRODUCT_TEXT
      end

      # One customer-facing reply for a supported multi-intent turn. The canonical, well-formed
      # same-variant price+stock composite (a price leg then a binary stock leg, both naming the SAME
      # validated code) names that code ONCE in the price clause and refers back to it with a natural
      # referential subject in the stock clause ("The price for CHILD-1 is USD 125.50 per Nos. It is
      # currently in stock."), so the deterministic text reads naturally and its token inventory no
      # longer forces a generated candidate to repeat the code. Any other shape — a noncanonical order,
      # a missing/blank or CONFLICTING code, or a non price+stock pair — falls back to the fail-closed
      # per-part join, whose every leg still names its own validated code. Both deliver each authorized
      # outcome once, with no duplicated fact and no second delivery.
      def composite_text(descriptor)
        parts = Array(descriptor[:parts])
        same_variant_price_stock_text(parts) ||
          parts.filter_map { |part| single_descriptor_text(part) if part.is_a?(Hash) }.join(' ')
      end

      # The deterministic sentence for ONE child descriptor (the same mapping reply_text applies to a
      # standalone reply, excluding the plan-level send_catalog branch a composite part never uses).
      def single_descriptor_text(descriptor)
        dynamic_product_text(descriptor) || STATIC_PRODUCT_TEXT[descriptor[:kind]] || GENERIC_PRODUCT_TEXT
      end

      # True when the plan carries a DIRECT catalog descriptor (Phase 4 #plan_catalog), as
      # opposed to a catalog-assisted variant clarification (reply nil). Only a direct request
      # gets a catalog caption and a no-catalog fallback that never asks for a variant.
      def direct_catalog_request?(plan)
        plan.dig(:reply, :kind) == :catalog
      end

      # No usable catalog for a DIRECT request: never ask for a variant (there is nothing to
      # disambiguate). If one was already sent this flow, say so; otherwise state none is
      # available. Both are deterministic and reference only the row-derived family name. The
      # `already_sent` decision (document existence + flow marker) is made by the caller.
      def direct_catalog_fallback_text(descriptor, already_sent:)
        name = catalog_family_name(descriptor || {})
        if already_sent
          "I've already shared the #{name} catalog with you above."
        else
          "I'm sorry, I don't have a catalog available for #{name} right now."
        end
      end

      # Playground-only TRUTHFUL preview line for a DIRECT catalog request whose primary catalog
      # exists. A real conversation delivers the native attachment with the #catalog_ready_text
      # caption; the source-less preview CANNOT deliver a file, so it must never claim "Here is the
      # catalog". It states only that the catalog is available and would be shared in a real
      # conversation, and names solely the row-derived family — the accompanying read-only metadata
      # card carries the safe file details.
      def catalog_preview_available_text(descriptor)
        "The #{catalog_family_name(descriptor)} catalog is available and would be shared with the customer in a full conversation."
      end

      # Playground-only TRUTHFUL line for a REPEATED direct catalog request whose preview card was
      # already shown earlier this flow. The source-less preview never delivered a file — it only
      # rendered a read-only metadata card — so it must NEVER claim "I've already shared the catalog
      # with you above" (the real-delivery #direct_catalog_fallback_text wording, correct only when a
      # native attachment was actually sent). It states only that the preview is already shown and
      # that the file would be shared in a full conversation, naming solely the row-derived family.
      def catalog_preview_already_shown_text(descriptor)
        "The #{catalog_family_name(descriptor)} catalog preview is already shown above; the file would be shared in a full conversation."
      end

      # The deterministic, factless, unbranded acknowledgement for a product handoff, selected by the
      # bounded generic request category so the fallback is request-AWARE without asserting anything.
      def handoff_ack_text(category)
        HANDOFF_ACK_BY_CATEGORY.fetch(category, HANDOFF_ACK_TEXT)
      end

      def catalog_family_name(descriptor)
        descriptor[:family_name].presence || descriptor[:family_code] || 'that product'
      end

      private

      def dynamic_product_text(descriptor) # rubocop:disable Metrics/CyclomaticComplexity -- a flat per-kind dispatch
        case descriptor[:kind]
        when :parent_info then parent_info_text(descriptor)
        when :variant_info then "Here are the details for #{descriptor[:variant_code]}. Would you like the price or availability?"
        when :price_available then price_available_text(descriptor)
        when :stock_available, :stock_empty then stock_text(descriptor)
        when :clarify_family then clarify_family_text(descriptor[:candidates])
        when :clarify_variant then clarify_variant_text(descriptor[:attribute_names])
        when :catalog then catalog_ready_text(descriptor)
        end
      end

      # Binary availability naming the exact validated variant code so the deterministic fallback
      # grounds that immutable fact (the mask/gates then keep it byte-exact in any natural rephrase
      # or translation). The available line leads with the code and a plain definite statement rather
      # than a fixed upbeat opener, so ordinary availability replies stop reading as one canned
      # sentence; natural, context-adapted variation still comes from the model path. A blank/malformed
      # code (nil after the renderer's cleaning) falls back to the generic, product-agnostic sentence.
      def stock_text(descriptor)
        code = descriptor[:variant_code].presence
        case descriptor[:kind]
        when :stock_available then code ? "#{code} is currently in stock." : STATIC_PRODUCT_TEXT[:stock_available]
        when :stock_empty then code ? "I'm sorry, #{code} is currently out of stock." : STATIC_PRODUCT_TEXT[:stock_empty]
        end
      end

      # The natural deterministic text for the canonical same-variant price→stock composite, or nil for
      # any other shape (the caller then falls back to the per-part join). When it applies, the price
      # clause names the shared validated code and the stock clause refers back to it, so the code is
      # stated once. Canonical production order is price then stock.
      def same_variant_price_stock_text(parts)
        return nil unless parts.length == 2 && parts.all?(Hash)

        price, stock = parts
        return nil unless shared_composite_code(price, stock)

        "#{price_available_text(price)} #{referential_stock_clause(stock[:kind])}"
      end

      # The single validated code a canonical price→stock composite shares, or nil when the two parts
      # are not a price_available leg followed by a binary stock leg naming the SAME non-blank code (a
      # noncanonical order, a missing/blank code, or CONFLICTING codes all fail closed to nil).
      def shared_composite_code(price, stock)
        return nil unless price[:kind] == :price_available
        return nil unless %i[stock_available stock_empty].include?(stock[:kind])

        code = price[:variant_code].presence
        code if code && stock[:variant_code].presence == code
      end

      # The stock clause that refers back to a variant code already named earlier in the composite, so
      # that validated code is stated once. Mirrors #stock_text's binary wording with a pronoun subject.
      def referential_stock_clause(kind)
        case kind
        when :stock_available then 'It is currently in stock.'
        when :stock_empty then "I'm sorry, it is currently out of stock."
        end
      end

      def catalog_ready_text(descriptor)
        "Here is the product catalog for #{catalog_family_name(descriptor)}."
      end

      def parent_info_text(descriptor)
        name = descriptor[:family_name].presence || descriptor[:family_code]
        "You're asking about #{name}. Which specific variant would you like to know about?"
      end

      def price_available_text(descriptor)
        amount = [descriptor[:currency], descriptor[:price_list_rate]].compact.join(' ')
        subject = descriptor[:variant_code].presence
        text = subject ? "The price for #{subject} is #{amount}" : "The price is #{amount}"
        text += " per #{descriptor[:uom]}" if descriptor[:uom].present?
        "#{text}."
      end

      def clarify_family_text(candidates)
        names = Array(candidates).filter_map { |candidate| candidate[:name].presence || candidate[:code] }
        return 'Could you tell me which product you are interested in?' if names.empty?

        "Could you let me know which product you mean? For example: #{names.join(', ')}."
      end

      def clarify_variant_text(attribute_names)
        names = Array(attribute_names).reject(&:blank?)
        return 'Could you specify which variant you are interested in?' if names.empty?

        "Could you specify the #{names.join(', ')} you need?"
      end
    end
  end
end
