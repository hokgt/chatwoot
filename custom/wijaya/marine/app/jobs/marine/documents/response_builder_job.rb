class Marine::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  def perform(document)
    return if document.content.blank?

    question = document.name.presence || document.external_link
    answer = document.content.to_s.truncate(4000)
    document.responses.find_or_create_by!(question: question) do |response|
      response.answer = answer
      response.assistant = document.assistant
      response.account = document.account
      response.status = :approved
    end
    document.update!(status: :available) unless document.available?
  end
end
