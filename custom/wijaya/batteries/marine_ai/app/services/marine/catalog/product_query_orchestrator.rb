# Phase 4 — Product Decision and State Machine Orchestrator.
#
# This is the integration DOMAIN layer that sits BEFORE any runtime side effect. It
# combines untrusted Phase 2 intent, the deterministic Phase 1 repositories, the
# Phase 3 canonical flow snapshot, and context-aware catalog reasoning into a single,
# strict, frozen ACTION PLAN. It deliberately performs NO side effects: it creates no
# Message/Attachment, calls no provider directly, writes no database row, and — most
# importantly — NEVER calls a ProductFlowStateStore mutation. Instead it accepts a
# safe current flow snapshot (ProductFlowStateStore#current output, string-keyed) and
# RETURNS a deterministic state-operation plan for a later runtime phase to apply.
#
# The only outbound reads are the Phase 1 repositories (parameterized, SELECT-only)
# and, when explicitly asked to process raw text, an INJECTED intent extractor
# (never the provider directly).
#
# Plan shape (top-level symbol keys; state changes use Phase 3 canonical string keys):
#   {
#     action:  one of ACTIONS,
#     reply:   a frozen ReplyRenderer descriptor or nil,
#     state:   { operation: :none | :start | :update, changes: { <flow keys> => ... } }
#   }
# operation :start maps to ProductFlowStateStore#start! (a fresh flow — which inherently
# clears any prior variant / attributes / catalog markers), :update maps to #update!,
# and :none means no state change. The plan is deeply frozen and contains only
# allowlisted deterministic fields — no raw stock quantity, warehouse detail, price row
# internals beyond the three approved fields, SQL, error, or ActiveRecord object.
module Marine
  module Catalog
    class ProductQueryOrchestrator
      ACTIONS = %i[not_product reply clarify_family clarify_variant send_catalog handoff stop].freeze
      STATE_OPERATIONS = %i[none start update].freeze

      # Intents that always demand an exact, validated child before any answer.
      VARIANT_REQUIRED_INTENTS = %w[price stock variant_info].freeze
      SUPPORTED_INTENTS = (VARIANT_REQUIRED_INTENTS + %w[parent_info]).freeze

      # Bounded safe family-candidate list surfaced with a clarify_family.
      CLARIFY_FAMILY_LIMIT = 10

      # `repositories` bundles the four Phase 1 read-only repositories under the keys
      # :family, :variant, :price, :stock (each defaulting to the real repository), so
      # dependency injection stays fully testable without a long parameter list.
      def initialize(intent_extractor: nil, repositories: {}, variant_resolver: nil, reply_renderer: nil)
        @intent_extractor = intent_extractor
        @family_repository = repositories[:family] || ProductFamilyRepository.new
        @variant_repository = repositories[:variant] || VariantRepository.new
        @price_repository = repositories[:price] || PriceRepository.new
        @stock_repository = repositories[:stock] || StockRepository.new
        @variant_resolver = variant_resolver || VariantResolver.new(variant_repository: @variant_repository)
        @reply_renderer = reply_renderer || ReplyRenderer.new
      end

      # Full path: extract intent from raw customer text (via the INJECTED extractor,
      # never the provider directly), then plan. Only this entry point touches the
      # extractor, so a no-provider test uses #plan_for_intent with a pre-extracted intent.
      def process(text:, context: nil, flow: nil, suppressed: false)
        intent = intent_extractor.extract(text: text, context: context, state: state_summary(flow))
        plan_for_intent(intent: intent, flow: flow, suppressed: suppressed)
      end

      # Deterministic planning over an already-extracted (untrusted) intent hash and a
      # safe flow snapshot. `suppressed` models the state-machine TERMINATED / duplicate /
      # stale transition (takeover/resolved/snoozed) that a later phase computes from
      # Eligibility/ProcessingClaim — when true, Marine emits no output.
      def plan_for_intent(intent:, flow: nil, suppressed: false)
        return build(:stop) if suppressed

        intent = symbolize(intent)
        flow = string_keyed(flow)

        return build(:not_product) unless truthy(intent[:product_related])

        intent = retain_flow_intent(intent, flow)
        return build(:handoff, reply: reply_renderer.unsupported) unless SUPPORTED_INTENTS.include?(intent[:intent].to_s)

        resolve_and_plan(intent, flow)
      rescue Marine::Catalog::Errors::CatalogError
        # Catalog/DB unavailable (including StockRepository's fail-closed unexpected
        # status): no fabricated fact — hand off with a safe, factless descriptor.
        build(:handoff, reply: reply_renderer.catalog_unavailable)
      end

      private

      attr_reader :family_repository, :variant_repository, :price_repository,
                  :stock_repository, :variant_resolver, :reply_renderer

      # A later runtime phase injects an account-aware extractor; the lazy default
      # keeps Phase 4 self-contained (extraction is only reached via #process).
      def intent_extractor
        @intent_extractor ||= IntentExtractor.new
      end

      # Code-only (or attribute-candidate) continuation while AWAITING_VARIANT: a bare
      # child code carries no re-extractable intent, so an `unknown`/`unsupported` extraction
      # would otherwise hand off and drop the flow. Deterministically retain the active flow's
      # variant-required current_intent (never fabricating family/child — repository validation
      # downstream stays mandatory). Only the planning intent value is swapped; an explicit
      # supported intent switch and a candidate-less message are left untouched.
      def retain_flow_intent(intent, flow)
        return intent unless continuation_retains_intent?(intent, flow)

        intent.merge(intent: flow['current_intent'])
      end

      def continuation_retains_intent?(intent, flow)
        return false unless %w[unknown unsupported].include?(intent[:intent].to_s)
        return false unless flow_active?(flow)
        return false if flow['validated_family'].to_s.strip.empty?
        return false if flow['validated_variant'].to_s.strip.present?
        return false unless new_candidates?(intent)

        VARIANT_REQUIRED_INTENTS.include?(flow['current_intent'].to_s)
      end

      def resolve_and_plan(intent, flow)
        continuing = continuing_family?(intent, flow)
        identifier = continuing ? flow['validated_family'] : intent[:family_mention]
        state_op = continuing ? :update : :start

        return clarify_family_plan(identifier) if identifier.to_s.strip.empty?

        # Every child/price/stock/catalog action is gated on a freshly revalidated,
        # row-derived family; resolve_exact fails closed (nil) for BOTH zero and
        # ambiguous matches, so an ambiguous family can never reach a catalog.
        family = family_repository.resolve_exact(identifier)
        return clarify_family_plan(identifier) if family.nil?

        if requires_variant?(intent)
          plan_variant(intent, flow, family, continuing, state_op)
        else
          plan_parent(intent, family, state_op)
        end
      end

      # Parent-level answer. On an intent switch to a parent-level intent within the same
      # flow (:update), close any pending variant clarification AND drop the now-stale
      # validated variant — Phase 3 #update! sanitization compacts the nil optional away.
      # A family switch (:start) already begins a fresh flow, so it carries neither key.
      def plan_parent(intent, family, state_op)
        changes = family_changes(family, intent).merge('expected_attributes' => [])
        changes = changes.merge('validated_variant' => nil) if state_op == :update
        build(:reply, reply: reply_renderer.parent_info(family), operation: state_op, changes: changes)
      end

      def plan_variant(intent, flow, family, continuing, state_op)
        code = resolved_variant_code(intent, flow, family, continuing)
        return await_variant(intent, flow, family, continuing, state_op) if code.nil?

        fulfill_variant(intent, family, code, state_op)
      end

      # A validated child comes from THIS message's candidates when present; otherwise,
      # while continuing the same family, from the flow's already-validated variant —
      # revalidated against the repository so a stale/removed child is never reused.
      def resolved_variant_code(intent, flow, family, continuing)
        if new_candidates?(intent)
          result = variant_resolver.resolve(family_code: family[:code],
                                            explicit_child_code: intent[:explicit_child_code],
                                            attribute_candidates: intent[:attribute_candidates])
          result[:status] == :resolved ? result[:code] : nil
        elsif continuing
          revalidate_existing_variant(flow, family[:code])
        end
      end

      def revalidate_existing_variant(flow, family_code)
        existing = flow['validated_variant']
        return nil if existing.to_s.strip.empty?

        row = variant_repository.resolve_child(family_code, existing)
        row && row[:code]
      end

      def fulfill_variant(intent, family, code, state_op)
        changes = family_changes(family, intent).merge('validated_variant' => code)
        case intent[:intent]
        when 'price' then plan_price(code, changes, state_op)
        when 'stock' then plan_stock(code, changes, state_op)
        else build(:reply, reply: reply_renderer.variant_info(family, code), operation: state_op, changes: changes)
        end
      end

      def plan_price(code, changes, state_op)
        price = price_repository.price_for(code)
        case price[:status]
        when :available
          build(:reply, reply: reply_renderer.price_available(price), operation: state_op, changes: changes)
        when :conflict
          # Fail closed: a conflicting price is never guessed — hand off to a human.
          build(:handoff, reply: reply_renderer.price_conflict, operation: state_op, changes: changes)
        else
          build(:reply, reply: reply_renderer.price_unavailable, operation: state_op, changes: changes)
        end
      end

      def plan_stock(code, changes, state_op)
        # :available / :empty only; an unexpected status raises CatalogUnavailableError,
        # caught by plan_for_intent and turned into a safe handoff (never a false empty).
        reply =
          case stock_repository.status_for(code)
          when :available then reply_renderer.stock_available
          when :empty then reply_renderer.stock_empty
          else raise Marine::Catalog::Errors::CatalogUnavailableError
          end
        build(:reply, reply: reply, operation: state_op, changes: changes)
      end

      # Variant unresolved -> stay AWAITING_VARIANT. Catalog is context-aware: only offered
      # when the customer has given nothing concrete to disambiguate AND the catalog has not
      # already been sent; any provided-but-unresolved code/attribute, ambiguous numbers, or
      # an already-sent catalog collapses to a plain text clarify_variant.
      def await_variant(intent, flow, family, continuing, state_op)
        attribute_names = variant_repository.attribute_names(family[:code])
        changes = family_changes(family, intent).merge('expected_attributes' => attribute_names)
        clarify = reply_renderer.clarify_variant(attribute_names)

        if catalog_already_sent?(flow, continuing) || truthy(intent[:multiple_numeric_candidates]) || new_candidates?(intent)
          build(:clarify_variant, reply: clarify, operation: state_op, changes: changes)
        else
          # Do NOT select a Marine::Document here; a later phase picks and sends it, then
          # marks catalog_sent — so the plan does not set the catalog markers itself.
          build(:send_catalog, operation: state_op, changes: changes)
        end
      end

      def clarify_family_plan(identifier)
        candidates = family_repository.active_candidates(query: identifier, limit: CLARIFY_FAMILY_LIMIT)
        build(:clarify_family, reply: reply_renderer.clarify_family(candidates))
      end

      # --- predicates -------------------------------------------------------------

      # Continue the existing flow's family only when it is active, has a validated family,
      # and the customer did not switch families. A family switch (or a fresh conversation)
      # falls through to a NEW flow (:start), which clears every prior variant/marker.
      def continuing_family?(intent, flow)
        flow_active?(flow) && flow['validated_family'].to_s.strip.present? && !truthy(intent[:family_changed])
      end

      def requires_variant?(intent)
        return false if intent[:intent] == 'parent_info'

        VARIANT_REQUIRED_INTENTS.include?(intent[:intent].to_s) || truthy(intent[:requires_exact_variant])
      end

      def new_candidates?(intent)
        intent[:explicit_child_code].to_s.strip.present? || Array(intent[:attribute_candidates]).any? { |v| v.to_s.strip.present? }
      end

      def catalog_already_sent?(flow, continuing)
        continuing && truthy(flow['catalog_sent'])
      end

      def flow_active?(flow)
        flow['status'] == ProductFlowStateStore::STATUS_ACTIVE
      end

      # --- builders / helpers -----------------------------------------------------

      def family_changes(family, intent)
        { 'validated_family' => family[:code], 'current_intent' => intent[:intent] }
      end

      def build(action, reply: nil, operation: :none, changes: {})
        deep_freeze(action: action, reply: reply, state: { operation: operation, changes: changes })
      end

      # A minimal, SAFE state summary for the intent extractor: only coarse, non-sensitive
      # hints (never a raw fact). awaiting_code is true when a family is validated but its
      # variant is not, so a bare numeric reply may be a code the assistant is waiting for.
      def state_summary(flow)
        flow = string_keyed(flow)
        {
          awaiting_code: flow_active?(flow) && flow['validated_family'].to_s.strip.present? && flow['validated_variant'].to_s.strip.empty?,
          current_family: flow['validated_family'],
          current_intent: flow['current_intent']
        }
      end

      def symbolize(intent)
        intent.is_a?(Hash) ? intent.symbolize_keys : {}
      end

      def string_keyed(flow)
        flow.is_a?(Hash) ? flow.transform_keys(&:to_s) : {}
      end

      def truthy(value)
        value == true || value == 'true' || value == 1
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }.freeze
        when Array then value.each { |v| deep_freeze(v) }.freeze
        else value.freeze
        end
      end
    end
  end
end
