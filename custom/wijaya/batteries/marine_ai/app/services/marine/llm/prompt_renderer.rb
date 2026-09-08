require 'liquid'

# Renders Marine prompt templates with Liquid, matching how Captain renders its
# prompts but without depending on Captain's on-disk template directory. Callers
# pass a template string plus a context hash; rendering failures degrade to the
# raw template so a bad variable never blocks a response.
class Marine::Llm::PromptRenderer
  class << self
    def render(template, context = {})
      return template.to_s if template.blank?

      Liquid::Template.parse(template.to_s).render(stringify(context))
    rescue Liquid::Error => e
      Rails.logger.warn("Marine::Llm::PromptRenderer render failed: #{e.message}")
      template.to_s
    end

    private

    def stringify(context)
      (context || {}).deep_stringify_keys
    end
  end
end
