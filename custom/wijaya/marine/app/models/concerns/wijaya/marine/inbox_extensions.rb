module Wijaya
  module Marine
    module InboxExtensions
      extend ActiveSupport::Concern

      included do
        has_one :marine_inbox, dependent: :destroy_async
        has_one :marine_assistant, through: :marine_inbox
      end

      def active_bot?
        super || marine_active?
      end

      def marine_active?
        marine_assistant.present?
      end
    end
  end
end
