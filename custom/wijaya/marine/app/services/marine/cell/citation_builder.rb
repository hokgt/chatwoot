class Marine::Cell::CitationBuilder
  # Builds JSON-safe citations from records that were actually retrieved.
  # Never exposes embeddings, secrets, or raw model internals.
  def self.build(responses)
    Array(responses).filter_map { |response| citation_for(response) }
  end

  def self.citation_for(response)
    return nil if response.nil?

    citation = {
      response_id: response.id,
      question: response.question,
      source_type: source_type_for(response)
    }
    document = document_for(response)
    if document
      citation[:document_id] = document.id
      citation[:document_name] = document.name.presence || document.display_url
      citation[:external_link] = document.external_link
    end
    citation
  end

  def self.source_type_for(response)
    return 'document' if document_for(response)
    return 'manual' if response.documentable_type.blank?

    response.documentable_type.to_s.demodulize.underscore
  end

  def self.document_for(response)
    documentable = response.documentable
    documentable if documentable.is_a?(Marine::Document)
  end
end
