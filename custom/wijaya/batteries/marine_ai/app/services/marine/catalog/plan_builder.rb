# Phase 4 — Plan descriptor assembly for the Product Decision orchestrator.
#
# A cohesive, side-effect-free helper mixed into ProductQueryOrchestrator. It owns
# construction of the deterministic ACTION PLAN envelope and its Phase 3 canonical
# state-change payloads, plus the deep freeze that makes every returned plan immutable.
# It reads no repository, calls no provider, and holds no state — pure structure
# building over already-decided, repository-derived facts — so the orchestrator stays
# focused on the decision / state-machine logic. Methods stay private in the includer.
module Marine
  module Catalog
    module PlanBuilder
      private

      def family_changes(family, intent)
        { 'validated_family' => family[:code], 'current_intent' => intent[:intent] }
      end

      # Changes for a family-level intent (parent_info, catalog) — neither carries a variant.
      # On an intent switch within the same flow (:update), close any pending variant
      # clarification AND drop the now-stale validated variant — Phase 3 #update! sanitization
      # compacts the nil optional away. A family switch (:start) already begins a fresh flow,
      # so it carries neither key.
      def family_level_changes(family, intent, state_op)
        changes = family_changes(family, intent).merge('expected_attributes' => [])
        changes = changes.merge('validated_variant' => nil) if state_op == :update
        cleared_clarification(changes, state_op)
      end

      # A RESOLVED plan represents validated progress, so on a continuation (:update) it clears
      # any prior clarification-progression metadata (Phase 3): kind, count, and the candidate-
      # family-code slot set. It also clears the pending multi-intent pair (requested_intents): once a
      # variant is validated the pair is fulfilled, so a later bare follow-up must not re-fulfill it.
      # The nils are compacted away by #update! sanitization. A fresh :start flow carries no such
      # metadata, so it is untouched.
      def cleared_clarification(changes, state_op)
        return changes unless state_op == :update

        changes.merge('clarification_kind' => nil, 'clarification_count' => nil,
                      'clarification_family_codes' => nil, 'requested_intents' => nil)
      end

      # The optional :language key is bounded delivery metadata (the customer-language
      # code the extractor read from the same turn). It rides alongside the plan for the
      # runtime localizer and never influences family/child/catalog selection. It is
      # omitted entirely when no usable code is available. The optional :handoff_category
      # key is the bounded, generic unsupported-request category (an explicit `category:`
      # override, else the per-turn @plan_handoff_category); it rides ONLY on a :handoff plan
      # and is delivery-only metadata for a request-aware acknowledgement — never a fact and
      # never a family/child/catalog influence.
      def build(action, reply: nil, operation: :none, changes: {}, category: nil)
        plan = { action: action, reply: reply, state: { operation: operation, changes: changes } }
        plan[:language] = @plan_language if @plan_language
        chosen_category = category || @plan_handoff_category
        plan[:handoff_category] = chosen_category if action == :handoff && chosen_category
        deep_freeze(plan)
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
