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

      # Bounded safe family-candidate list surfaced with a clarify_family.
      CLARIFY_FAMILY_LIMIT = 10

      # Phase 3 structured clarification progression. An unresolved structured state may be
      # clarified at most MAX_CLARIFICATIONS times; the NEXT (third) occurrence of the SAME
      # unresolved state — with no validated progress — hands off instead of clarifying again.
      MAX_CLARIFICATIONS = 2

      # Data-driven family recovery bounds. When the extracted mention is missing or noisy
      # and does not resolve, bounded normalized word tokens from the mention and the raw
      # turn are matched against the active family rows. A token must be at least
      # MIN_TOKEN_LENGTH chars; at most MAX_RECOVERY_TOKENS distinct tokens are considered;
      # and at most RECOVERY_FAMILY_LIMIT active rows are scanned (the repository clamps to
      # its own MAX_LIMIT regardless). No stopword/language/alias list is used.
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
      def process(text:, context: nil, flow: nil, suppressed: false)
        intent = intent_extractor.extract(text: text, context: context, state: state_summary(flow))
        plan_for_intent(intent: intent, flow: flow, suppressed: suppressed, text: text)
      end

      # Deterministic planning over an already-extracted (untrusted) intent hash and a
      # safe flow snapshot. `suppressed` models the state-machine TERMINATED / duplicate /
      # stale transition (takeover/resolved/snoozed) that a later phase computes from
      # Eligibility/ProcessingClaim — when true, Marine emits no output.
      # `text` is the OPTIONAL raw customer turn. When supplied (the full #process path),
      # it enables data-driven family recovery from the untrusted turn when the extracted
      # family mention is missing or noisy; direct-component callers may omit it.
      def plan_for_intent(intent:, flow: nil, suppressed: false, text: nil)
        intent = symbolize(intent)
        # Raw turn (family recovery) and bounded delivery language are captured per call
        # before any early return so every built plan carries consistent metadata.
        @turn_text = text.to_s
        @plan_language = normalize_language(intent[:customer_language])

        return build(:stop) if suppressed

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

      # Small coordinator: settle the canonical family decision/context for the turn, resolve the
      # row-derived family it implies, then dispatch to the matching catalog/variant/parent planner.
      # Both clarify exits surface the identifier the decision settled on (the raw mention for an
      # ambiguous raw-turn switch, the finalized identifier for an unresolved family).
      def resolve_and_plan(intent, flow)
        decision = family_decision(intent, flow)
        return clarify_family_plan(intent, flow, decision[:identifier]) if decision[:clarify]

        family = resolve_planned_family(decision)
        return clarify_family_plan(intent, flow, decision[:identifier]) if family.nil?

        dispatch_plan(intent, flow, family, decision[:continuing])
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

      # Dispatch a resolved family to the matching planner. Catalog needs no variant; a
      # variant-required intent awaits/fulfills a child, otherwise a parent-level answer.
      def dispatch_plan(intent, flow, family, continuing)
        state_op = continuing ? :update : :start
        return plan_catalog(intent, family, state_op) if intent[:intent] == 'catalog'

        if requires_variant?(intent)
          plan_variant(intent, flow, family, continuing, state_op)
        else
          plan_parent(intent, family, state_op)
        end
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
                                                intent: intent[:intent], family: family[:code],
                                                expected: attribute_names, flow: flow)
        return build(:handoff, reply: clarify) if progression[:handoff]

        changes = clarification_changes(family_changes(family, intent).merge('expected_attributes' => attribute_names),
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
      # clarification metadata (kind + count) so the SAME unresolved family state can be
      # counted across turns — on a fresh conversation via :start, on an active flow via
      # :update that PRESERVES the validated family and catalog markers (only current_intent
      # and the clarification metadata change). The third same-state occurrence hands off.
      def clarify_family_plan(intent, flow, identifier)
        reply = reply_renderer.clarify_family(family_repository.active_candidates(query: identifier, limit: CLARIFY_FAMILY_LIMIT))
        progression = clarification_progression(kind: ProductFlowStateStore::CLARIFICATION_KIND_FAMILY,
                                                intent: intent[:intent], family: flow['validated_family'],
                                                expected: nil, flow: flow)
        return build(:handoff, reply: reply) if progression[:handoff]

        changes = clarification_changes({ 'current_intent' => intent[:intent] },
                                        ProductFlowStateStore::CLARIFICATION_KIND_FAMILY, progression[:count])
        build(:clarify_family, reply: reply, operation: flow_active?(flow) ? :update : :start, changes: changes)
      end

      # Continuation switch detection. Classifies the DISTINCT active families evidenced by
      # bounded whole-token raw-turn matching relative to the flow's validated family:
      #   * exactly one active row that DIFFERS from the flow family -> that row (a genuine
      #     switch the caller applies with a fresh :start flow);
      #   * two or more distinct rows -> :ambiguous (the caller fails closed to clarify);
      #   * none, or a single row that IS the active family -> nil (continue/revalidate).
      # Same bounded token/whole-token matching and repository read-only access as recovery.
      def raw_turn_switch_family(intent, flow)
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

      # Data-driven recovery for a missing/noisy mention. Draws bounded, normalized word
      # tokens from BOTH the extracted mention and the raw customer turn, then keeps only
      # the active family rows evidenced by the turn — a row-derived code token, or ANY
      # single row-derived name token (so a partial mention of a multi-word family, e.g.
      # one word of its name, still recovers). Promotes a family ONLY when the evidence
      # converges on exactly one distinct active row; zero, several, or conflicting matches
      # (two families sharing the partial token/fragment) return nil so the caller
      # clarifies. No stopword/language/alias list — a token that matches nothing simply
      # contributes nothing, and any ambiguity fails closed. Read-only repository access.
      def recover_family(identifier)
        matches = matched_families(identifier)
        matches.first if matches.length == 1
      end

      # Distinct active families evidenced by bounded whole-token matching over the extracted
      # mention AND the raw turn, deduplicated by code (empty when no bounded token is
      # present). Shared by #recover_family and #raw_turn_switch_family. Read-only repository
      # access bounded by RECOVERY_FAMILY_LIMIT (the repository clamps to its own MAX_LIMIT).
      def matched_families(identifier)
        tokens = recovery_tokens(identifier)
        return [] if tokens.empty?

        family_repository.active_candidates(limit: RECOVERY_FAMILY_LIMIT)
                         .select { |family| family_named_by?(family, tokens) }
                         .uniq { |family| family[:code] }
      end

      # Bounded, deduplicated, lowercased word tokens drawn from the extracted mention and
      # the raw turn text.
      def recovery_tokens(identifier)
        [identifier, @turn_text].compact.join(' ').downcase
                                .scan(RECOVERY_TOKEN_PATTERN).uniq.first(MAX_RECOVERY_TOKENS).to_set
      end

      # A family is evidenced by the turn when its row-derived code appears as a whole
      # token, or when ANY single word token of its row-derived name is present as a whole
      # token. Matching is whole-token equality (never a substring in the middle of a
      # word), so a partial natural-language mention of a multi-word family — a single one
      # of its name words, or a contiguous run of them — is enough to evidence it. This is
      # deliberately permissive: when two families are both evidenced (they share the
      # partial token/fragment) #recover_family sees more than one distinct row and fails
      # closed to clarify rather than guessing between them.
      def family_named_by?(family, tokens)
        code = family[:code].to_s.strip.downcase
        return true if code.present? && tokens.include?(code)

        name_tokens = family[:name].to_s.downcase.scan(RECOVERY_TOKEN_PATTERN)
        name_tokens.any? { |token| tokens.include?(token) }
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

      def catalog_already_sent?(flow, continuing)
        continuing && truthy(flow['catalog_sent'])
      end

      def flow_active?(flow)
        flow['status'] == ProductFlowStateStore::STATUS_ACTIVE
      end

      # --- clarification progression (Phase 3) ------------------------------------

      # Count for an unresolved structured state and whether it must now hand off. The state
      # IDENTITY is generic — derived only from allowlisted structured state (clarification
      # kind, current supported intent, validated family when any, and — for a variant — the
      # repository expected attributes), NEVER raw customer text, candidate values, LLM output,
      # prices, stock, SQL, or errors. A repeat of the SAME identity on the SAME active flow
      # increments the count; any change (kind, intent, family, expected attrs), a fresh/expired
      # flow, or validated progress resets to 1. The third occurrence (count past the max) hands
      # off. Validated progress is expressed by the caller planning a resolved (non-clarify)
      # action, which clears the metadata instead of reaching here.
      def clarification_progression(kind:, intent:, family:, expected:, flow:)
        repeat = same_prior_clarification?(flow, kind: kind, intent: intent, family: family, expected: expected)
        count = repeat ? prior_clarification_count(flow) + 1 : 1
        { count: count, handoff: count > MAX_CLARIFICATIONS }
      end

      # True only when the flow already carries a prior occurrence of the EXACT same unresolved
      # structured state. Requires an ACTIVE flow (a fresh/expired flow can carry no prior
      # occurrence) and a positive persisted count (a dropped/malformed count reads as none).
      def same_prior_clarification?(flow, kind:, intent:, family:, expected:)
        return false unless flow_active?(flow)
        return false unless flow['clarification_kind'].to_s == kind
        return false unless flow['current_intent'].to_s == intent.to_s
        return false unless flow['validated_family'].to_s == family.to_s
        if kind == ProductFlowStateStore::CLARIFICATION_KIND_VARIANT &&
           normalized_attributes(flow['expected_attributes']) != normalized_attributes(expected)
          return false
        end

        prior_clarification_count(flow).positive?
      end

      # The persisted clarification count is already store-sanitized to a bounded integer or
      # absent; a non-integer here reads as zero (no prior occurrence).
      def prior_clarification_count(flow)
        value = flow['clarification_count']
        value.is_a?(Integer) ? value : 0
      end

      # Canonicalize both prior (persisted) and current expected attributes through the SAME
      # store trust boundary before comparison, so identity survives a pathological repository
      # list: the persisted value and the freshly-canonicalized turn value share exactly one
      # normalization (bounded, control-stripped, blank-rejected, deduplicated, capped). The
      # result is additionally SORTED here — for identity comparison ONLY — so the SAME
      # canonical set surfaced in a different repository order still compares equal (and never
      # falsely resets the progression to occurrence 1), while a genuinely changed set still
      # differs. The store's canonical persistence/descriptor order is left untouched.
      def normalized_attributes(value)
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
