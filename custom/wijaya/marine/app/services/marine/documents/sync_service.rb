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
  rescue ContentError => e
    handle_failure('website_no_readable_content', e)
  rescue StandardError => e
    handle_failure('website_sync_failed', e)
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

    document = Nokogiri::HTML(html)
    remove_unwanted_nodes(document)
    container = readable_container(document)
    return '' if container.nil?

    normalize_content(container).truncate(MAX_CONTENT_LENGTH, omission: '')
  end

  def remove_unwanted_nodes(document)
    UNWANTED_TAGS.each { |tag| document.css(tag).each(&:remove) }
    UNWANTED_PATTERNS.each do |pattern|
      document.css("[class*='#{pattern}'], [role*='#{pattern}']").each(&:remove)
    end
  end

  def readable_container(document)
    document.at_css('main') || document.at_css('article') || document.at_css('section') || document.at_css('body')
  end

  def normalize_content(container)
    blocks = container.css(CONTENT_BLOCKS)
    if blocks.any?
      normalized_blocks = blocks.filter_map { |node| normalize_block(node.text).presence }
      return normalized_blocks.join("\n\n")
    end

    container.text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
  end

  def normalize_block(text)
    text.gsub(/\s+/, ' ').strip
  end

  def handle_failure(code, error)
    Rails.logger.warn({ tag: 'marine.website.sync_failed', error_class: error.class.name, error_code: code }.to_json)
    mark_failed(code)
    { ok: false, content_length: 0, error: code }
  end

  def mark_failed(code)
    @document.update!(sync_status: :failed, last_sync_attempted_at: Time.current, last_sync_error_code: code)
  rescue StandardError => e
    Rails.logger.error({ tag: 'marine.website.sync_failed_persist', error_class: e.class.name }.to_json)
  end
end
