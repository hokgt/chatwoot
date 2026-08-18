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
        changes
      end

      # The optional :language key is bounded delivery metadata (the customer-language
      # code the extractor read from the same turn). It rides alongside the plan for the
      # runtime localizer and never influences family/child/catalog selection. It is
      # omitted entirely when no usable code is available.
      def build(action, reply: nil, operation: :none, changes: {})
        plan = { action: action, reply: reply, state: { operation: operation, changes: changes } }
        plan[:language] = @plan_language if @plan_language
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
