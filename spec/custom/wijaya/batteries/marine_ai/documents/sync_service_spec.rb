# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::SyncService do
  let(:document) { create(:marine_document, :website) }
  let(:service) { described_class.new(document) }

  it 'persists and returns a stable code without leaking a fetch exception message' do
    secret = 'connection failed for http://internal.example/token-secret'
    allow(service).to receive(:fetch_page).and_raise(StandardError, secret)

    result = service.call

    expect(result).to eq(ok: false, content_length: 0, error: 'website_sync_failed')
    expect(document.reload.last_sync_error_code).to eq('website_sync_failed')
    expect(result.to_json).not_to include(secret)
  end

  it 'uses a stable code when fetched HTML has no readable content' do
    allow(service).to receive(:fetch_page).and_return('<html><body><script>hidden</script></body></html>')

    result = service.call

    expect(result[:error]).to eq('website_no_readable_content')
    expect(document.reload.last_sync_error_code).to eq('website_no_readable_content')
  end
end
