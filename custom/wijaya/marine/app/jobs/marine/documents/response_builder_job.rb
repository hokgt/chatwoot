class Marine::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  def perform(document)
    Marine::Documents::SyncService.new(document).call if document.content.blank? && document.external_link.present?
    return if document.content.blank?

    # Marine Cell: store a deterministic knowledge entry from the document body.
    question = document.name.presence || document.external_link
    answer = document.content.to_s.truncate(4000)
    response = document.responses.find_or_initialize_by(question: question)
    response.assign_attributes(
      answer: answer,
      assistant: document.assistant,
      account: document.account,
      status: :approved
    )
    response.save!
    document.update!(status: :available) unless document.available?
  end
end
