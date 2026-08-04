# frozen_string_literal: true

require 'rails_helper'

# Deletion behavior with the restrictive Marine foreign keys in place. Every parent
# deletion must complete without a PG::ForeignKeyViolation (children removed in the
# same transaction) and must not leave orphaned rows or ActiveStorage blobs.
RSpec.describe 'Marine deletion behavior', type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def marine_response(assistant:, **attrs)
    Marine::AssistantResponse.create!(
      { assistant: assistant, question: 'q', answer: 'a', skip_embedding_enqueue: true }.merge(attrs)
    )
  end

  describe 'Marine::Assistant#destroy' do
    it 'removes all assistant-scoped children in one transaction without FK errors' do
      website_doc = create(:marine_document, :website, assistant: assistant)
      marine_response(assistant: assistant)
      marine_response(assistant: assistant, documentable: website_doc)
      create(:marine_scenario, assistant: assistant, account: account)
      inbox = create(:inbox, account: account)
      assistant.marine_inboxes.create!(inbox: inbox)
      thread = create(:marine_copilot_thread, account: account, assistant: assistant, user: create(:user, account: account))
      thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' })

      expect { assistant.destroy! }.not_to raise_error

      expect(Marine::Document.where(assistant_id: assistant.id)).to be_empty
      expect(Marine::AssistantResponse.where(assistant_id: assistant.id)).to be_empty
      expect(Marine::Scenario.where(assistant_id: assistant.id)).to be_empty
      expect(MarineInbox.where(marine_assistant_id: assistant.id)).to be_empty
      expect(Marine::CopilotThread.where(assistant_id: assistant.id)).to be_empty
      expect(Marine::CopilotMessage.where(account_id: account.id)).to be_empty
    end
  end

  describe 'Account#destroy' do
    it 'removes every account-scoped Marine record without FK errors' do
      create(:marine_document, :website, assistant: assistant)
      marine_response(assistant: assistant)
      create(:marine_scenario, assistant: assistant, account: account)
      create(:marine_custom_tool, account: account)
      thread = create(:marine_copilot_thread, account: account, assistant: assistant, user: create(:user, account: account))
      thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' })

      expect { account.destroy! }.not_to raise_error

      expect(Marine::Assistant.where(account_id: account.id)).to be_empty
      expect(Marine::Document.where(account_id: account.id)).to be_empty
      expect(Marine::AssistantResponse.where(account_id: account.id)).to be_empty
      expect(Marine::Scenario.where(account_id: account.id)).to be_empty
      expect(Marine::CustomTool.where(account_id: account.id)).to be_empty
      expect(Marine::CopilotThread.where(account_id: account.id)).to be_empty
      expect(Marine::CopilotMessage.where(account_id: account.id)).to be_empty
    end
  end

  describe 'Inbox#destroy' do
    it 'removes the marine_inbox link row without FK errors' do
      inbox = create(:inbox, account: account)
      link = assistant.marine_inboxes.create!(inbox: inbox)

      expect { inbox.destroy! }.not_to raise_error
      expect(MarineInbox.where(id: link.id)).to be_empty
      expect(Marine::Assistant.where(id: assistant.id)).to be_present
    end
  end

  describe 'User#destroy' do
    it 'removes the user-owned copilot threads and their messages without FK errors' do
      user = create(:user, account: account)
      thread = create(:marine_copilot_thread, account: account, assistant: assistant, user: user)
      thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' })

      expect { user.destroy! }.not_to raise_error
      expect(Marine::CopilotThread.where(id: thread.id)).to be_empty
      expect(Marine::CopilotMessage.where(copilot_thread_id: thread.id)).to be_empty
    end
  end

  describe 'Marine::CopilotThread#destroy' do
    it 'removes its messages without FK errors' do
      thread = create(:marine_copilot_thread, account: account, assistant: assistant, user: create(:user, account: account))
      thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' })

      expect { thread.destroy! }.not_to raise_error
      expect(Marine::CopilotMessage.where(copilot_thread_id: thread.id)).to be_empty
    end
  end

  describe 'Marine::Document#destroy' do
    it 'destroys documentable responses and purges the attached source file' do
      website_doc = create(:marine_document, :website, assistant: assistant)
      response = marine_response(assistant: assistant, documentable: website_doc)

      catalog_doc = create(:marine_document, :product_catalog, assistant: assistant)
      blob = catalog_doc.source_file.blob

      perform_enqueued_jobs { catalog_doc.destroy! }
      website_doc.destroy!

      expect(Marine::AssistantResponse.where(id: response.id)).to be_empty
      expect(ActiveStorage::Blob.where(id: blob.id)).to be_empty
      expect(ActiveStorage::Attachment.where(record_type: 'Marine::Document', record_id: catalog_doc.id)).to be_empty
    end
  end
end
