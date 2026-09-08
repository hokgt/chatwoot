# Rewrites/improves the agent's current draft text using the Marine LLM.
# Marine-owned rewrite service. Operation names match the
# composer's REWRITE_ACTIONS so Marine-linked conversations reuse the existing
# composer AI menu without any new/duplicate actions.
class Marine::Copilot::RewriteService < Marine::Copilot::BaseService
  OPERATION_INSTRUCTIONS = {
    'improve' => 'Improve the writing: make it clearer, more polished and professional while preserving meaning.',
    'fix_spelling_grammar' => 'Correct spelling and grammar mistakes only. Do not change meaning, tone, or style.',
    'expand' => 'Expand the message with a little more helpful detail while keeping it on-topic and concise.',
    'shorten' => 'Make the message shorter and more concise while preserving all key information.',
    'rephrase' => 'Rephrase the message using different wording while preserving its meaning and tone.',
    'simplify' => 'Simplify the message so it is easy to read and understand, using plain language.',
    'casual' => 'Rewrite the message in a casual, friendly and approachable tone.',
    'professional' => 'Rewrite the message in a professional and polished business tone.',
    'friendly' => 'Rewrite the message in a warm and friendly tone.',
    'make_friendly' => 'Rewrite the message in a warm and friendly tone.',
    'make_formal' => 'Rewrite the message in a formal and courteous tone.',
    'confident' => 'Rewrite the message in a confident and assertive tone.',
    'straightforward' => 'Rewrite the message in a clear and straightforward tone.'
  }.freeze

  ALLOWED_OPERATIONS = OPERATION_INSTRUCTIONS.keys.freeze

  def initialize(account:, content:, operation:, conversation: nil)
    super(account: account, conversation: conversation)
    @content = content.to_s
    @operation = operation.to_s
  end

  def perform
    return validation_error('invalid_operation') unless ALLOWED_OPERATIONS.include?(@operation)
    return validation_error('blank_content') if @content.strip.blank?

    run_completion(system: system_prompt, prompt: @content, event_name: @operation)
  end

  private

  def system_prompt
    <<~PROMPT.strip
      You are an assistant that rewrites a customer-support agent's draft message.
      #{OPERATION_INSTRUCTIONS[@operation]}
      Keep the same language as the original draft, and preserve names, numbers, URLs and formatting.
      Return only the rewritten message, with no labels, prefixes, or quotation marks.
    PROMPT
  end
end
