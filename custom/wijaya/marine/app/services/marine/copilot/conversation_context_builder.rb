# Builds a plain-text transcript of a conversation for Marine composer tasks.
# It mirrors Captain's character-budget approach so long threads never blow the
# model context, but stays Marine-owned and dependency-free. Never raises: a
# blank/absent conversation yields an empty transcript.
class Marine::Copilot::ConversationContextBuilder
  # Roughly 400k characters (~120k tokens); matches Captain's conservative budget.
  CHARACTER_LIMIT = 400_000

  def initialize(conversation)
    @conversation = conversation
  end

  # Oldest-first transcript of public incoming/outgoing messages.
  def transcript
    return '' if @conversation.blank?

    lines = []
    character_count = 0

    conversation_messages.each do |message|
      content = message.content_for_llm.to_s.strip
      next if content.blank?
      break if character_count + content.length > CHARACTER_LIMIT

      speaker = message.incoming? ? 'Customer' : 'Agent'
      lines.prepend("#{speaker}: #{content}")
      character_count += content.length
    end

    lines.join("\n")
  end

  private

  def conversation_messages
    @conversation.messages
                 .where(message_type: [:incoming, :outgoing])
                 .where(private: false)
                 .reorder('id desc')
  end
end
