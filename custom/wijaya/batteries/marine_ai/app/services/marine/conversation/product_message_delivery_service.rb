# Phase 6 — Native outgoing delivery of a single Product Catalog attachment. Builds ONE
# native outgoing Message from the Marine assistant carrying EXACTLY ONE native
# Attachment that REUSES the selected Marine::Document's existing ActiveStorage
# source_file blob (no re-upload, no OCR/extraction/conversion, no new blob), then saves
# the message so Chatwoot's native message-create callbacks / SendReplyJob deliver it. It
# NEVER calls a provider/channel API directly. The attachment is built on the unsaved
# message and persisted by the single `message.save!` (mirroring Messages::MessageBuilder),
# so the outgoing delivery callback sees the message and its one attachment atomically.
# Reusing an already-persisted blob via ActiveStorage `attach(blob)` is the same native
# interface the mail ingestion path uses; it copies no bytes. Returns the created Message.
class Marine::Conversation::ProductMessageDeliveryService
  include ::FileTypeHelper

  def initialize(conversation:, assistant:, document:, content:)
    @conversation = conversation
    @assistant = assistant
    @document = document
    @content = content
  end

  def call
    blob = @document.source_file.blob
    message = build_message
    attachment = message.attachments.build(account_id: @conversation.account_id, file_type: file_type(blob.content_type))
    attachment.file.attach(blob)
    message.save!
    message
  end

  private

  def build_message
    @conversation.messages.build(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: @assistant,
      content: @content,
      additional_attributes: { source_type: 'marine_product', orchestration_path: 'product' }
    )
  end
end
