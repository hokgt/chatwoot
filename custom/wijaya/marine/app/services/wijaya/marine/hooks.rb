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

      def marine_handling_conversation?(conversation:, inbox:)
        conversation.pending? && inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
      end

      def should_process_marine_response?(conversation, inbox, message)
        conversation.pending? && message.incoming? && inbox.respond_to?(:marine_assistant) && inbox.marine_assistant.present?
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
