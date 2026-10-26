# frozen_string_literal: true

# State/quiet-period guard shared by pre-generation and under-lock persistence checks.
class Marine::Memory::LifecyclePolicy
  OPEN_STATUSES = %w[open pending].freeze

  def initialize(conversation:, quiet_period:)
    @conversation = conversation
    @quiet_period = quiet_period
  end

  def error(state)
    return 'conversation_not_resolved' if state == 'final' && !conversation.resolved?
    return unless state == 'checkpoint'
    return 'checkpoint_ineligible_status' unless conversation.status.in?(OPEN_STATUSES)
    return 'checkpoint_not_quiet' unless quiet?
  end

  private

  attr_reader :conversation, :quiet_period

  def quiet?
    latest = conversation.messages.where(private: false, message_type: %i[incoming outgoing])
                         .reorder(created_at: :desc, id: :desc).first
    latest.present? && latest.created_at <= quiet_period.ago
  end
end
