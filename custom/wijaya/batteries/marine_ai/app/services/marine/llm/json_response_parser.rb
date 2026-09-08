# Parses JSON/object payloads returned by an LLM. Models frequently wrap JSON in
# prose or ```json fences, so this extracts the first balanced JSON object/array
# and falls back to a caller-supplied default instead of raising.
class Marine::Llm::JsonResponseParser
  def initialize(default: {})
    @default = default
  end

  def parse(response)
    return response if response.is_a?(Hash) || response.is_a?(Array)

    text = response.to_s
    return @default if text.blank?

    JSON.parse(stripped(text))
  rescue JSON::ParserError
    extracted = extract_json(text)
    return @default if extracted.blank?

    begin
      JSON.parse(extracted)
    rescue JSON::ParserError
      @default
    end
  end

  private

  # Remove markdown code fences (```json ... ```) that models often add.
  def stripped(text)
    text.gsub(/```(?:json)?/i, '').strip
  end

  # Grab the first {...} or [...] block from surrounding prose.
  def extract_json(text)
    match = text.match(/\{.*\}/m) || text.match(/\[.*\]/m)
    match && match[0]
  end
end
