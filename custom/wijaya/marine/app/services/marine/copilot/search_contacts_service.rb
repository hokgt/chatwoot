# Marine copilot contact search. Runs a deterministic search over the account's
# contacts (name / email / phone) and returns JSON-safe citation rows. Returns an
# empty array when the current user has no contact access so nothing leaks.
class Marine::Copilot::SearchContactsService < Marine::Copilot::SearchBaseService
  def perform(query: nil, email: nil, phone_number: nil, name: nil, limit: MAX_RESULTS)
    return [] unless contacts_accessible?

    contacts = filtered_contacts(query, email, phone_number, name).limit(limit)

    contacts.map do |contact|
      contact_citation(contact).merge(summary: safe_llm_text(contact))
    end
  end

  private

  def filtered_contacts(query, email, phone_number, name)
    contacts = account.contacts
    contacts = contacts.where('LOWER(email) = ?', email.downcase) if email.present?
    contacts = contacts.where(phone_number: phone_number) if phone_number.present?
    contacts = contacts.where('name ILIKE ?', "%#{name}%") if name.present?
    contacts = keyword_filter(contacts, query) if query.present?
    contacts.order(created_at: :desc)
  end

  def keyword_filter(contacts, query)
    term = "%#{query.to_s.strip}%"
    contacts.where(
      'name ILIKE :term OR email ILIKE :term OR phone_number ILIKE :term OR identifier ILIKE :term',
      term: term
    )
  end

  def safe_llm_text(contact)
    contact.to_llm_text.to_s.truncate(1500)
  rescue StandardError
    contact.name.to_s
  end
end
