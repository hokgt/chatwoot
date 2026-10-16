# frozen_string_literal: true

require 'rails_helper'

# Integration of the native conversation message `retry` seam with the whatsapp_web
# battery: a failed WhatsApp Web outgoing message re-emits a real message.created
# connector delivery (battery), while any other API inbox keeps the native retry path.
RSpec.describe 'Conversation message retry (whatsapp_web seam)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  def wa_inbox
    channel = account.api_channels.create!(hmac_mandatory: true,
                                           webhook_url: 'https://connector.internal/webhooks/wa',
                                           additional_attributes: { 'wijaya_provider' => 'whatsapp_web' })
    account.inboxes.create!(name: 'WA', channel: channel)
  end

  def plain_api_inbox
    channel = account.api_channels.create!(webhook_url: 'https://example.com/hook')
    account.inboxes.create!(name: 'API', channel: channel)
  end

  def failed_outgoing_message(inbox)
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
    conversation = create(:conversation, account: account, inbox: inbox, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: :outgoing, status: :failed, external_error: '503 Service Unavailable')
  end

  def retry_path(message)
    "/api/v1/accounts/#{account.id}/conversations/#{message.conversation.display_id}/messages/#{message.id}/retry"
  end

  before { allow(Webhooks::Trigger).to receive(:execute) }

  context 'when the inbox is a WhatsApp Web inbox' do
    it 're-emits a message.created connector delivery and skips the native send path' do
      message = failed_outgoing_message(wa_inbox)
      allow(SendReplyJob).to receive(:perform_later)

      post retry_path(message), headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(Webhooks::Trigger).to have_received(:execute).with(
        'https://connector.internal/webhooks/wa',
        hash_including(event: 'message_created', id: message.id),
        :api_inbox_webhook,
        hash_including(:secret, :delivery_id)
      )
      expect(SendReplyJob).not_to have_received(:perform_later)
    end
  end

  context 'when the inbox is an ordinary API inbox' do
    it 'keeps the native retry behaviour (SendReplyJob, no battery re-emit)' do
      message = failed_outgoing_message(plain_api_inbox)
      allow(SendReplyJob).to receive(:perform_later)

      post retry_path(message), headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(SendReplyJob).to have_received(:perform_later).with(message.id)
      expect(Webhooks::Trigger).not_to have_received(:execute)
    end
  end
end
