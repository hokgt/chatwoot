# Generates concise contact "memory" notes from a resolved conversation while
# staying fully Marine-owned: it uses only Marine::Llm::BaseService
# (Marine credentials/config) and avoids unrelated AI product gates.
#
# Notes are stored via the native contact.notes association Chatwoot already uses.
# Notes are system-authored (user_id left nil), because a Marine::Assistant
# is not a User and Note#user is optional.
#
# The entry point never raises into the caller/agent flow: an unconfigured or
# failing Marine LLM, or missing records, yields a safe no-op result hash.
#
#   { ok:, created:, error: }
class Marine::Memory::ContactNotesService
  def initialize(assistant:, conversation:)
    @assistant = assistant
    @conversation = conversation
    @contact = conversation&.contact
    @account = conversation&.account
  end

  def generate_and_store
    return no_op('missing_records') if @conversation.blank? || @contact.blank?
    return no_op('marine_llm_not_configured') unless base_service.configured?

    created = store_notes(generate_notes)
    { ok: true, created: created, error: nil }
  rescue StandardError => e
    capture(e)
    no_op(e.message)
  end

  private

  attr_reader :assistant, :conversation, :contact, :account

  def base_service
    @base_service ||= Marine::Llm::BaseService.new(account: account)
  end

  def generate_notes
    result = base_service.complete(prompt: content, system: system_prompt)
    return [] unless result[:ok] && result[:message].to_s.strip.present?

    parse_notes(result[:message])
  end

  # Dedupe: skip notes whose content already exists for this contact so replaying
  # the job (or re-resolving the same conversation) never creates duplicate memory
  # notes. Returns the number of notes actually created.
  def store_notes(notes)
    notes.count do |note|
      next false if contact.notes.exists?(content: note)

      contact.notes.create!(content: note)
      true
    end
  end

  def parse_notes(message)
    parsed = Marine::Llm::JsonResponseParser.new(default: {}).parse(message)
    notes = parsed.is_a?(Hash) ? parsed['notes'] : parsed
    Array(notes).map { |note| note.to_s.strip }.reject(&:blank?)
  end

  # Build LLM context from the native contact summary plus a Marine-owned transcript
  # that already excludes private notes and non-message system noise.
  def content
    "#Contact\n\n#{contact.to_llm_text}\n\n#Conversation\n\n#{transcript}"
  end

  def transcript
    Marine::Copilot::ConversationContextBuilder.new(conversation).transcript
  end

  def system_prompt
    <<~PROMPT.strip
      You extract durable, factual memory notes about a customer from a support conversation.
      Capture only stable, reusable facts (preferences, account details, recurring needs, commitments).
      Ignore greetings, small talk, and one-off pleasantries. Do not invent facts.
      Write each note as a short standalone sentence in #{account_locale_name}.
      Respond with a JSON object of the form {"notes": ["note one", "note two"]}.
      Return an empty notes array when there is nothing durable to remember.
    PROMPT
  end

  def account_locale_name
    account.respond_to?(:locale_english_name) ? account.locale_english_name : 'the account locale'
  end

  def no_op(error)
    { ok: false, created: 0, error: error.to_s.presence || 'marine_memory_failed' }
  end

  def capture(exception)
    return if account.blank?

    ChatwootExceptionTracker.new(exception, account: account).capture_exception
  end
end
