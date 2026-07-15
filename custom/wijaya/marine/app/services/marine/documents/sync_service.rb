class Marine::Documents::SyncService
  MAX_CONTENT_LENGTH = 200_000

  UNWANTED_TAGS = %w[script style nav footer header aside noscript svg form iframe].freeze
  UNWANTED_PATTERNS = %w[nav footer header sidebar menu banner cookie popup modal advertisement ad- social comment].freeze
  CONTENT_BLOCKS = 'p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, td'.freeze

  class ContentError < StandardError; end

  def initialize(document)
    @document = document
  end

  def call
    @document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
    content = extract_text(fetch_page)
    raise ContentError, 'No readable content found' if content.blank?

    @document.update!(
      content: content,
      status: :available,
      sync_status: :synced,
      last_synced_at: Time.current,
      last_sync_error_code: nil
    )
    { ok: true, content_length: content.length, error: nil }
  rescue StandardError => e
    mark_failed(e.message)
    { ok: false, content_length: 0, error: e.message }
  end

  private

  def fetch_page
    body = nil
    SafeFetch.fetch(@document.external_link, allowed_content_types: ['text/html']) do |result|
      body = result.tempfile.read
    end
    body
  end

  def extract_text(html)
    return '' if html.blank?

    doc = Nokogiri::HTML(html)
    UNWANTED_TAGS.each { |tag| doc.css(tag).each(&:remove) }
    UNWANTED_PATTERNS.each do |pattern|
      doc.css("[class*='#{pattern}'], [role*='#{pattern}']").each(&:remove)
    end

    container = doc.at_css('main') || doc.at_css('article') || doc.at_css('section') || doc.at_css('body')
    return '' if container.nil?

    blocks = container.css(CONTENT_BLOCKS)
    text = if blocks.any?
             blocks.filter_map { |node| node.text.gsub(/\s+/, ' ').strip.presence }.join("\n\n")
           else
             container.text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
           end
    text.truncate(MAX_CONTENT_LENGTH, omission: '')
  end

  def mark_failed(message)
    @document.update!(sync_status: :failed, last_sync_attempted_at: Time.current, last_sync_error_code: message)
  rescue StandardError => e
    Rails.logger.error("[Marine::Documents::SyncService] failed to persist failure state: #{e.message}")
  end
end
