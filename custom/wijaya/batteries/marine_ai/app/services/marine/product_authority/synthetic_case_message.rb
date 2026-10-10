# frozen_string_literal: true

# Fase 3A-2c — the SINGLE source of the DETERMINISTIC, fully-synthetic (SYN-PARITY) customer turn
# projected from a corpus acceptance case. The acceptance intake adapters AND the acceptance-only
# IntentExtractorSeam share this ONE projection, so the real intent seam receives EXACTLY the synthetic
# message the intake surfaces already use — no new text and no dataset is introduced.
#
# It is pure and side-effect-free: it reads ONLY the case id, the candidate intents, and a summary of
# the candidate slot operations; it validates nothing, looks nothing up, and mutates nothing.
module Marine::ProductAuthority::SyntheticCaseMessage
  # A deterministic, fully-synthetic, control-clean customer turn derived from the case: its id, its
  # candidate intents, and a summary of its slot operations. Bounded well within the decision contract's
  # message limit.
  def self.synthetic_message(kase)
    intents = plan_intents(kase).join(',')
    slots = Array(kase.dig(:plan, 'slot_operations')).filter_map { |op| slot_summary(op) }.join(',')
    "SYN-PARITY #{kase[:id]} intents=#{intents} slots=#{slots}"
  end

  def self.slot_summary(operation)
    return nil unless operation.is_a?(Hash)

    "#{operation['operation']}:#{operation['slot']}"
  end

  def self.plan_intents(kase)
    Array(kase.dig(:plan, 'intents')).select { |code| code.is_a?(String) }
  end
end
