module Wijaya
  module Marine
    module Hooks
      module_function

      def after_message_template_trigger(conversation:, inbox:, message:)
        return unless should_process_marine_response?(conversation, inbox, message)

        schedule_marine_response(conversation, message)
      rescue StandardError => e
        ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
      end

      def after_conversation_resolved(conversation)
        inbox = conversation&.inbox
        return unless marine_memory_enabled?(conversation, inbox)

        ::Marine::Memory::GenerateContactNotesJob.perform_later(conversation)
      rescue StandardError => e
        ChatwootExceptionTracker.new(e, account: conversation&.account).capture_exception
      end

      def marine_memory_enabled?(conversation, inbox)
        return false if conversation.blank? || inbox.blank?

        assistant = inbox.respond_to?(:marine_assistant) ? inbox.marine_assistant : nil
        assistant.present? && assistant.respond_to?(:feature_memory) && assistant.feature_memory.present?
      end

      def marine_handling_conversation?(conversation:, inbox:)
        return false unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
        return false if conversation.resolved? || conversation.snoozed?
        # Marine handles the conversation until a human agent sends a reply.
        # We check for sender_type 'User' (human) — Marine's own replies use
        # sender_type 'Marine::Assistant' and must not block subsequent turns.
        conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
      end

      def should_process_marine_response?(conversation, inbox, message)
        return false unless message.incoming?
        return false unless inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
        return false if conversation.resolved? || conversation.snoozed?
        # Marine handles until a human agent replies.  WhatsApp conversations
        # are created as 'open' (not 'pending' like web widget), so we check
        # for human (User) outgoing messages instead of the conversation status.
        conversation.messages.outgoing.where(private: false).where(sender_type: 'User').empty?
      end

      def schedule_marine_response(conversation, message)
        job_args = [conversation, conversation.inbox.marine_assistant]
        if message.attachments.blank?
          ::Marine::Conversation::ResponseBuilderJob.perform_later(*job_args)
        else
          ::Marine::Conversation::ResponseBuilderJob.set(wait: 2.seconds).perform_later(*job_args)
        end
      end
    end
  end
end