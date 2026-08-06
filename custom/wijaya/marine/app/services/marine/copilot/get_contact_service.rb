# Marine copilot single-contact fetch. Resolves a contact by id within the
# account and returns citation metadata plus its LLM text. Returns nil when the
# contact is not in this account or the user lacks contact access.
class Marine::Copilot::GetContactService < Marine::Copilot::SearchBaseService
  def perform(id:)
    return nil if id.blank?
    return nil unless contacts_accessible?

    contact = account.contacts.find_by(id: id)
    return nil if contact.blank?

    contact_citation(contact).merge(summary: safe_llm_text(contact))
  end

  private

  def safe_llm_text(contact)
    contact.to_llm_text.to_s.truncate(4000)
  rescue StandardError
    contact.name.to_s
  end
end
