# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Conversation::ProductMessageDeliveryService, type: :model do
  let(:conversation) { create(:conversation) }
  let(:assistant) { create(:marine_assistant, account: conversation.account) }
  let(:document) do
    create(:marine_document, :product_catalog, assistant: assistant, product_family_code: 'IMP', status: :available)
  end

  def deliver(content: 'Could you specify the size you need?')
    described_class.new(conversation: conversation, assistant: assistant, document: document, content: content).call
  end

  it 'builds one native outgoing Marine message carrying exactly one attachment' do
    message = deliver

    expect(message).to be_persisted
    expect(message.message_type).to eq('outgoing')
    expect(message.sender).to eq(assistant)
    expect(message.content).to eq('Could you specify the size you need?')
    expect(message.attachments.count).to eq(1)
    expect(message.additional_attributes['source_type']).to eq('marine_product')
  end

  it 'reuses the existing document source_file blob without creating a new one' do
    document # materialize before counting
    blob_id = document.source_file.blob.id

    expect { deliver }.not_to change(ActiveStorage::Blob, :count)

    attachment = conversation.messages.outgoing.last.attachments.first
    expect(attachment.file.blob.id).to eq(blob_id)
  end

  it 'derives the native attachment file_type from the blob content type' do
    message = deliver

    # The :product_catalog fixture blob is a PDF, which maps to the :file file_type.
    expect(message.attachments.first.file_type).to eq('file')
  end
end
