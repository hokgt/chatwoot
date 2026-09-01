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
#     action:   one of ACTIONS,
#     reply:    a frozen ReplyRenderer descriptor or nil,
#     state:    { operation: :none | :start | :update, changes: { <flow keys> => ... } },
#     language: (optional) bounded customer-language code for delivery localization
#   }
# The optional :language key is untrusted delivery metadata drawn from the same intent
# extraction; it is present only when a usable code was extracted and never affects the
# family/child/catalog decision.
# operation :start maps to ProductFlowStateStore#start! (a fresh flow — which inherently
# clears any prior variant / attributes / catalog markers), :update maps to #update!,
# and :none means no state change. The plan is deeply frozen and contains only
# allowlisted deterministic fields — no raw stock quantity, warehouse detail, price row
# internals beyond the three approved fields, SQL, error, or ActiveRecord object.
module Marine
  module Catalog
    class ProductQueryOrchestrator # rubocop:disable Metrics/ClassLength
      # Plan envelope / state-change payload construction and deep freeze live in this
      # cohesive helper, keeping this class focused on the decision / state-machine logic.
      include PlanBuilder

      ACTIONS = %i[not_product reply clarify_family clarify_variant send_catalog handoff stop].freeze
      STATE_OPERATIONS = %i[none start update].freeze

      # Intents that always demand an exact, validated child before any answer.
      VARIANT_REQUIRED_INTENTS = %w[price stock variant_info].freeze
      SUPPORTED_INTENTS = (VARIANT_REQUIRED_INTENTS + %w[parent_info catalog]).freeze

      # Non-transactional product-KNOWLEDGE intents: the customer is asking WHAT a product is or is
      # like (its attributes/properties), not for a price, stock level, or catalog document. The
      # catalog repositories hold only codes, prices, and stock — never textual attributes such as
      # texture, material, use, or care — so when such a turn cannot be resolved to a concrete catalog
      # answer the ONLY thing the catalog can emit is an arbitrary "which product?" family
      # clarification. The approved Knowledge Base is where those attributes live, so an unresolved
      # knowledge turn is handed back to grounded KB retrieval instead of that deflection (see
      # #clarify_or_defer). Transactional intents (price/stock/catalog) are never deferred and keep
      # their deterministic clarify / fail-closed behavior. Generic and data-driven: no
      # attribute/product/language/phrase list.
      KNOWLEDGE_INTENTS = %w[parent_info variant_info].freeze

      # Transactional / deliverable intents that carry a DETERMINISTIC, repository-grounded (or
      # fail-closed) catalog answer and must therefore NEVER be diverted to grounded KB retrieval,
      # even when the KB has a confident match for the turn: price and stock are repository facts,
      # catalog is a native document delivery. Every OTHER product-related turn (parent_info,
      # variant_info, or an unsupported/unknown product turn) is INFORMATIONAL — its only catalog
      # output is an attribute-free identity echo or a clarification/handoff — so it may defer to the
      # approved Knowledge Base when the KB actually answers it (see #defer_to_knowledge?). An
      # exact-quantity ask is transactional-adjacent and is excluded separately via quantity_inquiry.
      TRANSACTIONAL_INTENTS = %w[price stock catalog].freeze

      # The only supported COMBINABLE pair for a single turn: price AND stock. Both are supported,
      # repository-grounded, variant-required intents, so one turn asking for both is fulfilled with a
      # single composite reply (assembled from the existing price/stock descriptors) rather than
      # dropping either outcome. Any other multi-intent combination falls back to the primary intent.
      COMBINABLE_PAIR = %w[price stock].freeze

      # Defensive per-turn bound on the requested-intent set at this trust boundary (the extractor
      # already bounds/dedupes/allowlists it; a persisted/forged flow value is re-normalized here).
      MAX_REQUESTED_INTENTS = 4

      # Bounded safe family-candidate list surfaced with a clarify_family.
      CLARIFY_FAMILY_LIMIT = 10

      # Phase 3 structured clarification progression. An unresolved structured state may be
      # clarified at most MAX_CLARIFICATIONS times; the NEXT (third) occurrence of the SAME
      # unresolved state — with no validated progress — hands off instead of clarifying again.
      MAX_CLARIFICATIONS = 2

      # Data-driven family recovery bounds. When the extracted mention is missing or noisy
      # and does not resolve, bounded normalized word tokens from the mention and the raw
      # turn are SCORED against the active family rows (see #family_evidence_score) so the
      # most-specific family — the one whose code/name the customer actually typed — wins over
      # a family that a lone generic request word incidentally collides with. A token must be
      # at least MIN_TOKEN_LENGTH chars; at most MAX_RECOVERY_TOKENS ordered tokens are
      # considered; and the scored candidate pool is the deduped UNION of the repository's
      # case-insensitive search over each token (see #recovery_candidate_families), each
      # search bounded by RECOVERY_FAMILY_LIMIT (the repository clamps to its own MAX_LIMIT).
      # The pool is thus derived from what the turn actually mentions rather than an arbitrary
      # item_code-ordered prefix, so a family is reachable regardless of its item_code
      # position. No stopword/language/alias list is used.
      MIN_TOKEN_LENGTH = 2
      MAX_RECOVERY_TOKENS = 24
      RECOVERY_FAMILY_LIMIT = 50
      RECOVERY_TOKEN_PATTERN = /[[:alnum:]]{#{MIN_TOKEN_LENGTH},}/

      # Bounded, allowlisted customer-language format (a FORMAT allowlist, never a list of
      # languages/phrases): a 2–3 letter primary subtag with an optional single subtag.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

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
      def process(text:, context: nil, flow: nil, suppressed: false, knowledge_available: false)
        intent = intent_extractor.extract(text: text, context: context, state: state_summary(flow))
        plan_for_intent(intent: intent, flow: flow, suppressed: suppressed, text: text, knowledge_available: knowledge_available)
      end

      # Deterministic planning over an already-extracted (untrusted) intent hash and a
      # safe flow snapshot. `suppressed` models the state-machine TERMINATED / duplicate /
      # stale transition (takeover/resolved/snoozed) that a later phase computes from
      # Eligibility/ProcessingClaim — when true, Marine emits no output.
      # `text` is the OPTIONAL raw customer turn. When supplied (the full #process path),
      # it enables data-driven family recovery from the untrusted turn when the extracted
      # family mention is missing or noisy; direct-component callers may omit it.
      def plan_for_intent(intent:, flow: nil, suppressed: false, text: nil, knowledge_available: false)
        intent = symbolize(intent)
        capture_turn_metadata(intent, text, knowledge_available)

        return build(:stop) if suppressed

        flow = string_keyed(flow)

        return build(:not_product) unless truthy(intent[:product_related])

        # Effective supported-intent SET for this turn, computed from the untrusted extraction BEFORE
        # retain_flow_intent rewrites the scalar intent: the turn's own stated set wins, and a bare
        # follow-up that states nothing inherits any bounded pending pair from the active flow (so a
        # clarification later fulfills the still-valid pair; a genuinely new stated intent replaces it).
        @requested_intents = effective_requested_intents(intent, flow)

        intent = retain_flow_intent(intent, flow)
        # An INFORMATIONAL product turn the approved KB confidently answers defers to grounded KB
        # retrieval (:not_product) instead of an attribute-free catalog identity echo, a variant
        # clarification, or an unsupported-request handoff — so an approved KB fact about a product is
        # surfaced rather than hidden by catalog interception. Fires only when the KB actually answers
        # (never a fabricated deflection) and never for a transactional price/stock/catalog or
        # exact-quantity turn, whose deterministic / fail-closed behavior is preserved below. Runs
        # AFTER retain_flow_intent so an active price/stock variant continuation is already excluded.
        return build(:not_product) if defer_to_knowledge?(intent)
        return build(:handoff, reply: reply_renderer.unsupported) unless SUPPORTED_INTENTS.include?(intent[:intent].to_s)

        resolve_and_plan(intent, flow)
      rescue Marine::Catalog::Errors::CatalogError
        # Catalog/DB unavailable (including StockRepository's fail-closed unexpected
        # status): no fabricated fact — hand off with a safe, factless descriptor.
        build(:handoff, reply: reply_renderer.catalog_unavailable)
      end

      private

      # Per-call turn metadata captured before any early return so every built plan carries it
      # consistently: the raw turn (data-driven family recovery), the bounded delivery language and
      # unsupported-request handoff category, and the injected KB-availability signal. The last is
      # whether the approved Knowledge Base confidently answers THIS turn's query — computed by the
      # runtime (which owns KB access) and injected so this domain layer stays free of any
      # KB/retrieval coupling; it is only ever CONSULTED for an informational turn (see
      # #defer_to_knowledge?) and can never redirect a transactional price/stock/catalog or
      # exact-quantity turn. It defaults false, so every existing direct caller keeps its unchanged
      # deterministic catalog behavior.
      def capture_turn_metadata(intent, text, knowledge_available)
        @turn_text = text.to_s
        @plan_language = normalize_language(intent[:customer_language])
        @plan_handoff_category = normalize_unsupported_request(intent[:unsupported_request])
        @knowledge_available = knowledge_available
      end

      attr_reader :family_repository, :variant_repository, :price_repository,
                  :stock_repository, :variant_resolver, :reply_renderer

      # A later runtime phase injects an account-aware extractor; the lazy default
      # keeps Phase 4 self-contained (extraction is only reached via #process).
      def intent_extractor
        @intent_extractor ||= IntentExtractor.new
      end

      # A candidate-only continuation while AWAITING_VARIANT: the customer is supplying the child
      # code / attribute the flow is waiting for, not opening a new request. A bare code carries no
      # re-extractable intent (an `unknown`/`unsupported` extraction), and the provider may ALSO emit a
      # volatile informational label (e.g. `variant_info`) for that very same slot answer — both would
      # otherwise drop the active variant-required flow and answer the wrong question. Deterministically
      # retain the active flow's variant-required current_intent (never fabricating family/child —
      # repository validation downstream stays mandatory). Only the planning intent value is swapped; a
      # genuine explicit intent switch and a candidate-less message are left untouched.
      def retain_flow_intent(intent, flow)
        return intent unless continuation_retains_intent?(intent, flow)

        intent.merge(intent: flow['current_intent'])
      end

      def continuation_retains_intent?(intent, flow)
        return false unless awaiting_variant_slot?(flow)
        return false unless new_candidates?(intent)
        return false unless retainable_continuation_label?(intent, flow)

        VARIANT_REQUIRED_INTENTS.include?(flow['current_intent'].to_s)
      end

      # The AWAITING_VARIANT precondition: an active flow with a validated family but no validated
      # variant yet — the state in which a variant-required current_intent is waiting on a
      # child/attribute slot answer.
      def awaiting_variant_slot?(flow)
        active_validated_flow?(flow) && flow['validated_variant'].to_s.strip.empty?
      end

      # Whether the extracted label of a candidate-only continuation may be overridden by the flow's
      # retained intent. A bare code extracts as `unknown`/`unsupported` (no re-extractable intent) and
      # is always retainable. A SUPPORTED label is retained ONLY when it differs from the flow's current
      # intent AND the provider affirmatively classified the message as a mere slot answer
      # (intent_scope == 'slot_value') — a volatile informational relabel of a candidate reply. A
      # message that explicitly states a new business intent (intent_scope 'new_intent'), or carries a
      # missing/uncertain scope, is NEVER retained, so a genuine supported switch — and any multi-intent
      # turn — is preserved. Fail-closed on an unknown scope: the extracted intent wins.
      def retainable_continuation_label?(intent, flow)
        label = intent[:intent].to_s
        return true if %w[unknown unsupported].include?(label)
        return false if label == flow['current_intent'].to_s

        slot_value_continuation?(intent)
      end

      # The provider affirmatively classified the latest message as merely supplying the awaited slot
      # value (not stating a new intent). Read from the bounded, allowlisted extractor field; a
      # missing/unknown scope is not a slot-value classification, so the extracted intent stands.
      def slot_value_continuation?(intent)
        intent[:intent_scope].to_s == 'slot_value'
      end

      # Small coordinator: settle the canonical family decision/context for the turn, resolve the
      # row-derived family it implies, then dispatch to the matching catalog/variant/parent planner.
      # Both clarify exits surface the identifier the decision settled on (the raw mention for an
      # ambiguous raw-turn switch, the finalized identifier for an unresolved family).
      def resolve_and_plan(intent, flow)
        decision = family_decision(intent, flow)
        return clarify_or_defer(intent, flow, decision[:identifier]) if decision[:clarify]

        family = resolve_planned_family(decision)
        return clarify_or_defer(intent, flow, decision[:identifier]) if family.nil?

        dispatch_plan(intent, flow, family, decision[:continuing])
      end

      # An unresolved family would otherwise become an arbitrary "which product?" family
      # clarification. For a non-transactional product-KNOWLEDGE turn (KNOWLEDGE_INTENTS) that
      # carries no catalog-grounded answer, hand the turn back to grounded KB retrieval
      # (:not_product) so an attribute question the approved Knowledge Base can answer is not
      # deflected; the Runner's #product_payload returns nil for :not_product and falls through to
      # the unchanged RAG path. A transactional turn (price/stock/catalog) still clarifies the family
      # deterministically and fails closed. Only the unresolvable-family clarification defers — every
      # resolved catalog answer and the variant-level clarification are untouched.
      def clarify_or_defer(intent, flow, identifier)
        return build(:not_product) if KNOWLEDGE_INTENTS.include?(intent[:intent].to_s)

        clarify_family_plan(intent, flow, identifier)
      end

      # True when this INFORMATIONAL product turn should defer to grounded KB retrieval because the
      # approved Knowledge Base confidently answers it. Requires the injected knowledge_available
      # signal; never fires for a transactional / deliverable intent (TRANSACTIONAL_INTENTS) or an
      # exact-quantity ask (quantity_inquiry), so price/stock/catalog delivery and the exact-quantity
      # handoff stay deterministic and fail-closed. Every remaining product-related intent
      # (parent_info, variant_info, or an unsupported/unknown product turn) is informational — its
      # only catalog output is an attribute-free echo or a clarification/handoff — so the approved KB
      # answer, when present, wins. Generic and data-driven: the availability signal comes from the
      # runtime KB retrieval, not any attribute/product/language/phrase list here.
      def defer_to_knowledge?(intent)
        return false unless @knowledge_available
        return false if truthy(intent[:quantity_inquiry])

        TRANSACTIONAL_INTENTS.exclude?(intent[:intent].to_s)
      end

      # Family decision/context for the turn. Returns the settled
      # { mentioned, switched, continuing, identifier }, or { clarify: true, identifier: } on an
      # ambiguous raw-turn switch.
      #
      # Extracted-family evidence has TOP priority. A NONBLANK mention resolved on its own — an
      # exact match, else a single active row — decides continue-vs-switch by CANONICAL identity,
      # NOT the string-level family_changed flag: that flag is mere text inequality against the flow
      # code and can be true even when the mention re-resolves to the SAME row, so continuation is
      # recomputed from the active-flow preconditions (active, with a nonblank validated family) AND
      # same_family?. A resolution to that same row continues it (:update); any other resolved
      # family — or an inactive/terminated flow carrying a stale family — is a genuine switch to a
      # fresh :start flow (which clears stale catalog markers). Incidental raw-turn tokens NEVER
      # override a resolved mention.
      #
      # Bounded whole-token raw-turn evidence is consulted ONLY when the extracted mention is blank
      # or did not resolve, and only on an active flow: a single active row that differs from the
      # flow family is a genuine switch (a fresh :start), ambiguous rows fail closed to clarify, and
      # no evidence (or only the active family) continues and revalidates the active family
      # unchanged.
      def family_decision(intent, flow)
        mention = intent[:family_mention]
        mentioned = resolve_family(mention) unless mention.to_s.strip.empty?
        continuing = family_continuation?(intent, flow, mentioned)

        switched = raw_turn_switch_family(intent, flow) if mentioned.nil? && continuing
        return { clarify: true, identifier: mention } if switched == :ambiguous

        continuing = false if switched
        { mentioned: mentioned, switched: switched, continuing: continuing,
          identifier: continuing ? flow['validated_family'] : mention }
      end

      # Continue-vs-switch precondition. A resolved mention continues only when it re-resolves to
      # the active flow's validated family (canonical identity, not the family_changed flag); with
      # no resolved mention, defer to the string-level continuing_family? check.
      def family_continuation?(intent, flow, mentioned)
        if mentioned
          active_validated_flow?(flow) && same_family?(mentioned, flow)
        else
          continuing_family?(intent, flow)
        end
      end

      # Every child/price/stock/catalog action is gated on a freshly revalidated, row-derived
      # family: the extracted resolution when present, else the raw-turn switch, else — on a
      # continuation — a revalidation of the active family (which clarifies rather than recovering
      # if it fails, so a bare reply can never silently switch), else a bounded data-driven recovery
      # from the raw turn tokens on a fresh NEW-family turn. Zero, multiple, or ambiguous candidates
      # still fail closed to clarify_family, so an ambiguous family can never reach a catalog.
      def resolve_planned_family(decision)
        decision[:mentioned] || decision[:switched] ||
          (decision[:continuing] ? resolve_family(decision[:identifier]) : recover_family(decision[:identifier]))
      end

      # Dispatch a resolved family to the matching planner. Catalog needs no variant; an exact
      # on-hand quantity is not exposed and hands off safely (never a misleading boolean stock
      # sentence); a variant-required intent awaits/fulfills a child, otherwise a parent-level
      # answer.
      def dispatch_plan(intent, flow, family, continuing)
        state_op = continuing ? :update : :start
        return plan_catalog(intent, family, state_op) if intent[:intent] == 'catalog'
        return plan_quantity_handoff(intent, family, state_op) if quantity_inquiry?(intent)

        if requires_variant?(intent)
          plan_variant(intent, flow, family, continuing, state_op)
        else
          plan_parent(intent, family, state_op)
        end
      end

      # A stock turn asking for an exact on-hand quantity: the catalog exposes only boolean
      # availability, so answering with the in-stock/out-of-stock sentence would be misleading.
      # Hand off with a safe, factless descriptor while PRESERVING the validated family context
      # (family-level changes, clearing any stale variant); a later phase acknowledges the request
      # and asks a human to confirm the exact quantity. Fires before variant resolution so the
      # customer is never first asked to pick a variant for a number Marine cannot provide anyway.
      # An exact on-hand quantity is never exposed. This fires for a single stock turn AND for a
      # supported pair that also asks for an exact count (stock is among the requested intents): the
      # whole turn hands off safely — the existing exact-quantity precedence is preserved rather than
      # partially exposing a price/availability answer for a request Marine cannot fully satisfy.
      def quantity_inquiry?(intent)
        return false unless truthy(intent[:quantity_inquiry])

        intent[:intent].to_s == 'stock' || @requested_intents.include?('stock')
      end

      def plan_quantity_handoff(intent, family, state_op)
        # An exact-quantity ask is, by definition, the exact_quantity request category — tag it
        # explicitly so the later handoff acknowledgement is request-aware even if the model did
        # not separately populate unsupported_request for this stock-intent turn.
        build(:handoff, reply: reply_renderer.unsupported, category: 'exact_quantity',
                        operation: state_op, changes: family_level_changes(family, intent, state_op))
      end

      # Direct Product Catalog request. After a freshly revalidated family (explicitly named
      # this turn, or reused from the active flow), send the catalog straight away — NO variant
      # is required. The reply descriptor marks this as a DIRECT catalog request so the runtime
      # renders a catalog caption / no-catalog fallback rather than a variant clarification.
      # A later phase selects and sends the document and sets catalog_sent; the plan sets no
      # catalog markers itself.
      def plan_catalog(intent, family, state_op)
        build(:send_catalog, reply: reply_renderer.catalog(family),
                             operation: state_op, changes: family_level_changes(family, intent, state_op))
      end

      # Parent-level answer. Catalog and parent are both family-level (no variant), so both
      # clear stale variant context via #family_level_changes.
      def plan_parent(intent, family, state_op)
        build(:reply, reply: reply_renderer.parent_info(family),
                      operation: state_op, changes: family_level_changes(family, intent, state_op))
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
        # A unique validated variant is validated progress, so clear any prior clarification
        # metadata on a continuation (:update); a :start already begins a metadata-free flow.
        changes = cleared_clarification(family_changes(family, intent).merge('validated_variant' => code), state_op)
        # A supported price+stock pair for the SAME validated variant fulfills BOTH in one composite
        # reply; otherwise the single primary intent decides the descriptor.
        return plan_composite(code, changes, state_op) if combinable_pair?

        case intent[:intent]
        when 'price' then plan_price(code, changes, state_op)
        when 'stock' then plan_stock(code, changes, state_op)
        else build(:reply, reply: reply_renderer.variant_info(family, code), operation: state_op, changes: changes)
        end
      end

      # Assemble ONE composite reply from the existing per-leg descriptors, in canonical order
      # (price then stock). A conflicting price still fails closed to a single handoff — a possibly
      # wrong price is never partially exposed; an unavailable stock repository raises
      # CatalogUnavailableError from #stock_descriptor and is caught by plan_for_intent (safe handoff).
      def plan_composite(code, changes, state_op)
        parts = COMBINABLE_PAIR.map { |leg| leg == 'price' ? price_descriptor(code) : stock_descriptor(code) }
        return build(:handoff, reply: reply_renderer.price_conflict, operation: state_op, changes: changes) if parts.include?(:conflict)

        build(:reply, reply: reply_renderer.composite(parts), operation: state_op, changes: changes)
      end

      def plan_price(code, changes, state_op)
        descriptor = price_descriptor(code)
        # Fail closed: a conflicting price is never guessed — hand off to a human.
        return build(:handoff, reply: reply_renderer.price_conflict, operation: state_op, changes: changes) if descriptor == :conflict

        build(:reply, reply: descriptor, operation: state_op, changes: changes)
      end

      def plan_stock(code, changes, state_op)
        build(:reply, reply: stock_descriptor(code), operation: state_op, changes: changes)
      end

      # The price descriptor for a validated child, or the :conflict signal (a conflicting price is
      # never rendered — the caller hands off). Read-only; only the three approved fields survive.
      def price_descriptor(code)
        price = price_repository.price_for(code)
        case price[:status]
        when :available then reply_renderer.price_available(price, code)
        when :conflict then :conflict
        else reply_renderer.price_unavailable
        end
      end

      # The binary stock-availability descriptor for a validated child, carrying that exact validated
      # `code` so a natural reply can name the product it reports on. :available / :empty only; an
      # unexpected status raises CatalogUnavailableError, caught by plan_for_intent and turned into a
      # safe handoff (never a false empty). Never a quantity — the repository collapses all bins first.
      def stock_descriptor(code)
        case stock_repository.status_for(code)
        when :available then reply_renderer.stock_available(code)
        when :empty then reply_renderer.stock_empty(code)
        else raise Marine::Catalog::Errors::CatalogUnavailableError
        end
      end

      # Variant unresolved -> stay AWAITING_VARIANT. Catalog is context-aware: only offered
      # when the customer has given nothing concrete to disambiguate AND the catalog has not
      # already been sent; any provided-but-unresolved code/attribute, ambiguous numbers, or
      # an already-sent catalog collapses to a plain text clarify_variant. Phase 3: this is a
      # structured VARIANT clarification occurrence — the third same-state occurrence with no
      # validated progress hands off (catalog-assisted send_catalog on occurrence 1 still
      # delivers the native catalog once; occurrence 2 is plain clarify with no re-send).
      def await_variant(intent, flow, family, continuing, state_op)
        # Canonicalize the repository attribute list ONCE through the store's trust boundary so
        # the customer-facing descriptor, the progression identity, and the persisted
        # expected_attributes all use the same bounded/deduplicated shape — a pathological
        # repository list can never make occurrence 1 and its persisted occurrence 2 differ.
        attribute_names = ProductFlowStateStore.normalize_expected_attributes(variant_repository.attribute_names(family[:code]))
        clarify = reply_renderer.clarify_variant(attribute_names)
        progression = clarification_progression(kind: ProductFlowStateStore::CLARIFICATION_KIND_VARIANT,
                                                family: family[:code], expected: attribute_names, flow: flow)
        return build(:handoff, reply: clarify) if progression[:handoff]

        changes = clarification_changes(family_changes(family, intent).merge('expected_attributes' => attribute_names).merge(pending_pair_changes),
                                        ProductFlowStateStore::CLARIFICATION_KIND_VARIANT, progression[:count])
        if catalog_already_sent?(flow, continuing) || truthy(intent[:multiple_numeric_candidates]) || new_candidates?(intent)
          build(:clarify_variant, reply: clarify, operation: state_op, changes: changes)
        else
          # Do NOT select a Marine::Document here; a later phase picks and sends it, then
          # marks catalog_sent — so the plan does not set the catalog markers itself.
          build(:send_catalog, operation: state_op, changes: changes)
        end
      end

      # Structured FAMILY clarification occurrence. Occurrences 1 and 2 record bounded
      # clarification metadata (kind + count + the candidate-family-code set that defines the
      # slot) so the SAME unresolved family state can be counted across turns — on a fresh
      # conversation via :start, on an active flow via :update that PRESERVES the validated family
      # and catalog markers (only current_intent and the clarification metadata change). The third
      # same-slot occurrence hands off; a genuinely different candidate set resets to occurrence 1.
      def clarify_family_plan(intent, flow, identifier)
        candidates = clarify_family_candidates(identifier)
        reply = reply_renderer.clarify_family(candidates)
        family_codes = candidate_family_codes(candidates)
        progression = clarification_progression(kind: ProductFlowStateStore::CLARIFICATION_KIND_FAMILY,
                                                family: flow['validated_family'], family_codes: family_codes, flow: flow)
        return build(:handoff, reply: reply) if progression[:handoff]

        base = { 'current_intent' => intent[:intent], 'clarification_family_codes' => family_codes }.merge(pending_pair_changes)
        changes = clarification_changes(base, ProductFlowStateStore::CLARIFICATION_KIND_FAMILY, progression[:count])
        build(:clarify_family, reply: reply, operation: flow_active?(flow) ? :update : :start, changes: changes)
      end

      # Bounded clarification candidates for the ACTUAL ambiguity. Prefer the repository's
      # case-insensitive candidate search on the settled identifier; when that yields nothing
      # (a noisy/poor identifier an ILIKE cannot match) fall back to the raw-turn evidence the
      # recovery scorer already surfaced, so a repository-identifiable ambiguity never degrades
      # to an empty, generic family prompt. Read-only.
      #
      # A BLANK identifier (the extractor flagged no family reference) surfaces NO examples: the
      # raw turn is untrusted here, so mining it would offer a family coincidentally matched by an
      # ordinary word as if it were a relevant example. A generic request therefore fails closed to
      # an example-free clarification (never an arbitrary catalog slice or a lone coincidental row).
      def clarify_family_candidates(identifier)
        return [] if identifier.to_s.strip.empty?

        candidates = selective_family_candidates(identifier)
        return candidates if candidates.present?

        matched_families(identifier).first(CLARIFY_FAMILY_LIMIT)
      end

      # The repository's direct candidate search, but ONLY for a genuinely selective (non-blank)
      # identifier. The repository treats a blank query as "no filter" and would return an
      # arbitrary item_code-ordered slice of the ENTIRE catalog — unrelated families surfaced as
      # if they were relevant examples. A blank identifier therefore yields nothing here so the
      # caller falls back to bounded raw-turn evidence (relevant candidates, or a generic,
      # example-free clarification when the turn names no family at all).
      def selective_family_candidates(identifier)
        return [] if identifier.to_s.strip.empty?

        family_repository.active_candidates(query: identifier, limit: CLARIFY_FAMILY_LIMIT)
      end

      # The bounded, canonical candidate-family-code SET that gives a FAMILY clarification its
      # durable slot identity — the same codes surfaced in the clarify_family reply, normalized
      # through the store's trust boundary so it round-trips identically with the persisted field.
      def candidate_family_codes(candidates)
        ProductFlowStateStore.normalize_expected_attributes(candidates.pluck(:code))
      end

      # Continuation switch detection for a NOISY-but-present mention. Classifies the DISTINCT
      # active families evidenced by bounded whole-token raw-turn matching relative to the flow's
      # validated family:
      #   * exactly one active row that DIFFERS from the flow family -> that row (a genuine
      #     switch the caller applies with a fresh :start flow);
      #   * two or more distinct rows -> :ambiguous (the caller fails closed to clarify);
      #   * none, or a single row that IS the active family -> nil (continue/revalidate).
      # Same bounded token/whole-token matching and repository read-only access as recovery.
      #
      # A BLANK mention means the extractor flagged NO family reference for this turn: symmetric
      # with #recover_family on a fresh turn, the untrusted raw turn must not switch away from the
      # validated family, or an ordinary word coincidentally equal to one family's name token would
      # abandon the active catalog for a request that named nothing (the reported runtime shape).
      # Returning nil here is safe continuation — the caller keeps and revalidates the existing
      # active family — never a switch or handoff. The extractor's mention is the only structural
      # signal distinguishing a named family from an extractor miss, so it is trusted identically
      # mid-flow and on a fresh flow.
      def raw_turn_switch_family(intent, flow)
        return nil if intent[:family_mention].to_s.strip.empty?

        matches = matched_families(intent[:family_mention])
        return nil if matches.empty?
        return :ambiguous if matches.length > 1

        row = matches.first
        row unless same_family?(row, flow)
      end

      # Exact-match priority, then a safe, data-driven promotion: when no exact family
      # matches the (possibly partial) identifier, the bounded active-family search may
      # stand in for it ONLY when it yields exactly one active family. Any other count —
      # zero or several — returns nil so the caller clarifies, never guessing a family.
      def resolve_family(identifier)
        family_repository.resolve_exact(identifier) || unique_active_family(identifier)
      end

      # Data-driven recovery for a NOISY-but-present mention. Scores the active family rows
      # against the mention + raw turn (see #matched_families / #family_evidence_score) and
      # promotes a family ONLY when a SINGLE family holds the top score. A genuine tie at the
      # top (competing equally-specific families) or no evidence at all returns nil so the
      # caller clarifies — a family is never guessed between real ambiguities. No stopword/
      # language/alias list — specificity is derived only from the active rows themselves.
      #
      # A BLANK identifier means the extractor flagged NO family reference for this turn: the raw
      # turn alone must not auto-resolve a family, or an ordinary word that coincidentally equals
      # one family's name token would select a catalog from a request that named nothing
      # (the reported runtime shape). The extractor's mention is the trusted family-identification signal;
      # with none, this fresh turn fails closed to a generic clarification rather than mining the
      # untrusted turn text.
      def recover_family(identifier)
        return nil if identifier.to_s.strip.empty?

        matches = matched_families(identifier)
        matches.first if matches.length == 1
      end

      # The active families sharing the single best evidence score over the extracted mention
      # AND the raw turn, deduplicated by code (empty when the turn carries no bounded family
      # evidence). Shared by #recover_family and #raw_turn_switch_family: a unique top scorer
      # is a confident recovery/switch, a top-score tie is real ambiguity the callers fail
      # closed on, and the tied rows are the actual candidates a clarification surfaces.
      #
      # Scoring deliberately does NOT weight every raw-turn token equally (that let a generic
      # request word which happens to be one word of an UNRELATED family name manufacture a
      # false second match): each active family is scored by #family_evidence_score and only
      # the families sharing the maximal score survive. Read-only repository access bounded by
      # RECOVERY_FAMILY_LIMIT (the repository clamps to its own MAX_LIMIT).
      def matched_families(identifier)
        sequence = recovery_sequence(identifier)
        return [] if sequence.empty?

        top_scored_families(score_active_families(sequence))
      end

      # Each active family paired with its evidence score over the ordered turn tokens, keeping
      # only the families the turn actually evidences (a nonzero span).
      def score_active_families(sequence)
        tokens = sequence.to_set
        families = recovery_candidate_families(tokens)
        frequency = family_token_frequency(families)

        families.filter_map do |family|
          score = family_evidence_score(family, sequence, tokens, frequency)
          [family, score] unless score.first.zero?
        end
      end

      # The active families the turn could plausibly evidence: the deduped union of the
      # repository's bounded, case-insensitive candidate search over EACH distinct turn token.
      # Every active family whose row-derived code/name contains a token the customer typed is
      # fetched regardless of its position in item_code order, so recovery no longer silently
      # ignores families outside an arbitrary item_code-ordered prefix. Read-only; bounded by
      # the token count (<= MAX_RECOVERY_TOKENS) times the repository's own per-search limit.
      def recovery_candidate_families(tokens)
        tokens.flat_map { |token| family_repository.active_candidates(query: token, limit: RECOVERY_FAMILY_LIMIT) }
              .uniq { |family| family[:code] }
      end

      # The families sharing the single maximal evidence score (one row => confident recovery,
      # several => real ambiguity the callers fail closed on).
      def top_scored_families(scored)
        return [] if scored.empty?

        best = scored.map { |(_, score)| score }.max
        scored.select { |(_, score)| score == best }.map(&:first)
      end

      # Ordered, bounded, lowercased word tokens drawn from the extracted mention and the raw
      # turn text — order preserved so #contiguous_span can measure phrase contiguity; the
      # callers derive the deduplicated set from it.
      def recovery_sequence(identifier)
        [identifier, @turn_text].compact.join(' ').downcase.scan(RECOVERY_TOKEN_PATTERN).first(MAX_RECOVERY_TOKENS)
      end

      # Deterministic evidence score for one active family as a comparable [span, specificity]
      # tuple (higher wins; an exactly equal tuple ties and fails closed to clarify):
      #   * span — the LONGEST run of CONSECUTIVE turn tokens that all belong to this family's
      #     identity (its row-derived code/name tokens). A customer who typed a contiguous chunk
      #     of ONE family's name outscores a family evidenced only by an isolated generic word
      #     that incidentally collides with one of its name words — closing the false-ambiguity
      #     defect without any stopword/language/phrase list.
      #   * specificity — the sum of 1/corpus-frequency (exact Rational) over this family's
      #     identity tokens present in the turn, where corpus frequency is how many ACTIVE
      #     families share the token. A token unique to one family contributes 1; a token shared
      #     by N families contributes 1/N, so a lone shared token can never break a tie (every
      #     sharer scores it identically) and only a token UNIQUE across active identities lets
      #     its family win. Data-driven from the active rows; read-only.
      def family_evidence_score(family, sequence, tokens, frequency)
        identity = identity_tokens(family)
        [contiguous_span(identity, sequence), identity_specificity(identity, tokens, frequency)]
      end

      # Longest run of consecutive turn tokens all belonging to the family identity set.
      def contiguous_span(identity, sequence)
        best = current = 0
        sequence.each do |token|
          current = identity.include?(token) ? current + 1 : 0
          best = current if current > best
        end
        best
      end

      # Sum of 1/corpus-frequency (exact Rational so equally specific families compare
      # bit-identically and tie) over the family identity tokens present in the turn.
      def identity_specificity(identity, tokens, frequency)
        identity.sum(Rational(0)) { |token| tokens.include?(token) ? Rational(1, frequency[token]) : Rational(0) }
      end

      # Corpus frequency: how many DISTINCT active families each identity token appears in.
      def family_token_frequency(families)
        families.each_with_object(Hash.new(0)) do |family, frequency|
          identity_tokens(family).each { |token| frequency[token] += 1 }
        end
      end

      # A family's bounded identity token set: its row-derived name word tokens plus, when
      # present, its whole row-derived code as a single token.
      def identity_tokens(family)
        tokens = family[:name].to_s.downcase.scan(RECOVERY_TOKEN_PATTERN)
        code = family[:code].to_s.strip.downcase
        tokens << code if code.present?
        tokens.to_set
      end

      # LIMIT 2 lets a unique active family be told apart from an ambiguous one without
      # fetching the whole clarify list; the single row (its row-derived code/name) is
      # promoted only when exactly one exists.
      def unique_active_family(identifier)
        candidates = family_repository.active_candidates(query: identifier, limit: 2)
        candidates.first if candidates.length == 1
      end

      # --- predicates -------------------------------------------------------------

      # Continue the existing flow's family only when it is active, has a validated family,
      # and the customer did not switch families. A family switch (or a fresh conversation)
      # falls through to a NEW flow (:start), which clears every prior variant/marker.
      def continuing_family?(intent, flow)
        active_validated_flow?(flow) && !truthy(intent[:family_changed])
      end

      # Active flow that already carries a validated family — the precondition, independent of
      # the string-level family_changed flag, for continuing (vs. starting) a flow when the
      # canonical family for the turn is already known. An inactive/terminated flow with a
      # stale family therefore never continues on same_family? alone.
      def active_validated_flow?(flow)
        flow_active?(flow) && flow['validated_family'].to_s.strip.present?
      end

      # A resolved family row IS the active flow family when their row-derived codes match.
      def same_family?(family, flow)
        family[:code].to_s == flow['validated_family'].to_s
      end

      def requires_variant?(intent)
        return false if intent[:intent] == 'parent_info'

        VARIANT_REQUIRED_INTENTS.include?(intent[:intent].to_s) || truthy(intent[:requires_exact_variant])
      end

      def new_candidates?(intent)
        intent[:explicit_child_code].to_s.strip.present? || Array(intent[:attribute_candidates]).any? { |v| v.to_s.strip.present? }
      end

      # --- multi-intent (requested-intent set) ------------------------------------

      # True when the turn's effective supported set carries BOTH price and stock — the one supported
      # combinable pair — so the fulfillment renders a single composite reply.
      def combinable_pair?
        COMBINABLE_PAIR.all? { |intent| @requested_intents.include?(intent) }
      end

      # The effective supported-intent SET for this turn. The turn's OWN stated set wins (latest
      # intent replaces stale pending intents); a bare follow-up that states no supported intent
      # inherits a bounded pending pair persisted on the active flow, so a clarification can later
      # fulfill the still-valid pair. Everything is re-normalized (allowlisted, deduped, canonical,
      # bounded) at this trust boundary, so a forged/oversized persisted value can never widen it.
      def effective_requested_intents(intent, flow)
        stated = normalize_requested(intent[:requested_intents], intent[:intent])
        return stated if stated.present?

        retained_pending_pair(flow)
      end

      # A bounded pending pair carried on the active flow (only a genuine 2-element supported pair is
      # inherited; a single persisted intent or a non-active flow inherits nothing).
      def retained_pending_pair(flow)
        pair = normalize_requested(flow['requested_intents'], nil)
        flow_active?(flow) && pair.length >= 2 ? pair : []
      end

      # Fold an untrusted intent list (+ optional scalar fallback) into the bounded, deduped,
      # allowlisted, canonically ordered supported set. A missing/empty list falls back to the
      # supported scalar; an unsupported/unknown scalar yields []. Canonical order = SUPPORTED order.
      def normalize_requested(raw, scalar)
        list = Array(raw).filter_map { |item| item.to_s.strip.downcase.presence }
        list = [scalar.to_s.strip.downcase] if list.empty? && scalar
        supported = IntentExtractor::SUPPORTED_PRODUCT_INTENTS
        supported.select { |intent| list.include?(intent) }.first(MAX_REQUESTED_INTENTS)
      end

      # The bounded requested-intent pair to PERSIST on a clarify plan, so a later bare follow-up can
      # fulfill the still-valid pair. Only a genuine 2-element pair is persisted; a single intent is
      # already captured by current_intent, so nothing extra is written.
      def pending_pair_changes
        @requested_intents.length >= 2 ? { 'requested_intents' => @requested_intents } : {}
      end

      def catalog_already_sent?(flow, continuing)
        continuing && truthy(flow['catalog_sent'])
      end

      def flow_active?(flow)
        flow['status'] == ProductFlowStateStore::STATUS_ACTIVE
      end

      # --- clarification progression (Phase 3) ------------------------------------

      # Count for an unresolved structured state and whether it must now hand off. The state
      # IDENTITY is the DURABLE unresolved slot — derived only from allowlisted structured state
      # (clarification kind, validated family when any, and the bounded candidate set the slot is
      # blocked on: the repository expected attributes for a VARIANT, the candidate family codes
      # for a FAMILY). It NEVER depends on the volatile per-turn current_intent, nor on raw
      # customer text, candidate values, LLM output, prices, stock, SQL, or errors. A repeat of the
      # SAME slot on the SAME active flow increments the count; a changed kind/family/candidate
      # set, a fresh/expired flow, or validated progress resets to 1. The third occurrence (count
      # past the max) hands off. Validated progress is expressed by the caller planning a resolved
      # (non-clarify) action, which clears the metadata instead of reaching here.
      def clarification_progression(kind:, family:, flow:, expected: nil, family_codes: nil)
        repeat = same_prior_clarification?(flow, kind: kind, family: family, expected: expected, family_codes: family_codes)
        count = repeat ? prior_clarification_count(flow) + 1 : 1
        { count: count, handoff: count > MAX_CLARIFICATIONS }
      end

      # True only when the flow already carries a prior occurrence of the EXACT same unresolved
      # slot. Requires an ACTIVE flow (a fresh/expired flow can carry no prior occurrence) and a
      # positive persisted count (a dropped/malformed count reads as none).
      def same_prior_clarification?(flow, kind:, family:, expected:, family_codes:)
        return false unless flow_active?(flow)
        return false unless flow['clarification_kind'].to_s == kind
        return false unless flow['validated_family'].to_s == family.to_s
        return false unless same_unresolved_slot?(flow, kind, expected, family_codes)

        prior_clarification_count(flow).positive?
      end

      # The durable candidate SET the slot is blocked on, compared per kind: a VARIANT occurrence
      # is the SAME while the repository expected-attribute set matches; a FAMILY occurrence is the
      # SAME while the bounded candidate-family-code set matches. Both compare canonical sorted sets
      # so a different repository order never falsely resets the count. current_intent is
      # deliberately NOT consulted: a valid terse/rephrased clarification the extractor relabels
      # with a different supported intent is still the SAME unresolved slot and must keep advancing
      # toward the occurrence-3 handoff.
      def same_unresolved_slot?(flow, kind, expected, family_codes)
        case kind
        when ProductFlowStateStore::CLARIFICATION_KIND_VARIANT
          normalized_identity_set(flow['expected_attributes']) == normalized_identity_set(expected)
        when ProductFlowStateStore::CLARIFICATION_KIND_FAMILY
          normalized_identity_set(flow['clarification_family_codes']) == normalized_identity_set(family_codes)
        else
          true
        end
      end

      # The persisted clarification count is already store-sanitized to a bounded integer or
      # absent; a non-integer here reads as zero (no prior occurrence).
      def prior_clarification_count(flow)
        value = flow['clarification_count']
        value.is_a?(Integer) ? value : 0
      end

      # Canonicalize a bounded identity set (expected attributes OR candidate family codes) through
      # the SAME store trust boundary before comparison, so identity survives a pathological
      # repository list: the persisted value and the freshly-canonicalized turn value share exactly
      # one normalization (bounded, control-stripped, blank-rejected, deduplicated, capped). The
      # result is additionally SORTED here — for identity comparison ONLY — so the SAME canonical
      # set surfaced in a different repository order still compares equal (and never falsely resets
      # the progression to occurrence 1), while a genuinely changed set still differs. The store's
      # canonical persistence/descriptor order is left untouched.
      def normalized_identity_set(value)
        ProductFlowStateStore.normalize_expected_attributes(Array(value)).sort
      end

      # Attach the bounded clarification metadata (enum kind + bounded count) to a clarify
      # plan's state changes. Applied only in finalization by ResponseBuilderJob.
      def clarification_changes(changes, kind, count)
        changes.merge('clarification_kind' => kind, 'clarification_count' => count)
      end

      # --- builders / helpers -----------------------------------------------------

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

      # Defensive re-normalization of the (already extractor-normalized) untrusted
      # customer-language code into the bounded allowlisted format, or nil.
      def normalize_language(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        code if code.match?(LANGUAGE_PATTERN)
      end

      # Defensive re-normalization of the (already extractor-normalized) untrusted
      # unsupported-request category against the single-source generic allowlist, or nil. Never
      # affects family/child/catalog resolution — it is delivery-only handoff metadata.
      def normalize_unsupported_request(value)
        return nil unless value.is_a?(String)

        category = value.strip.downcase
        IntentExtractor::UNSUPPORTED_REQUEST_CATEGORIES.include?(category) ? category : nil
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
    end
  end
end
