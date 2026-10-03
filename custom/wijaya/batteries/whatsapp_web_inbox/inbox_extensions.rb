# frozen_string_literal: true

# Battery-owned extension attached to the native Inbox model (from the loader's
# to_prepare, so app/models/inbox.rb carries no markers). It adds the single
# association linking a native inbox to its WhatsApp Web connector mapping.
#
# dependent: :destroy is the primary cleanup path: when core deletes an inbox
# (DeleteObjectJob calls #destroy!), Rails destroys the mapping row, whose
# after_destroy_commit enqueues the idempotent connector-session cleanup job. The
# migration's on_delete: :cascade is the DB-level safety net for delete_all paths
# (which fire no callback — the remote session is then reaped by the connector's own
# lifecycle, never by a half-run Ruby callback).
# rubocop:disable Style/ClassAndModuleChildren -- nested style preserves sibling constant resolution
module Wijaya::Batteries::WhatsappWebInbox
  module InboxExtensions
    extend ActiveSupport::Concern

    included do
      has_one :wijaya_whatsapp_web_inbox,
              class_name: 'Wijaya::Batteries::WhatsappWebInbox::Record',
              dependent: :destroy
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
