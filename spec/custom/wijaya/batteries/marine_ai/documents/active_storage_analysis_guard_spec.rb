# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Marine::ActiveStorageAnalysisGuard, type: :model do
  it 'is prepended to ActiveStorage::Attachment' do
    expect(ActiveStorage::Attachment.ancestors).to include(described_class)
  end

  describe '#analyze_blob_later' do
    subject(:attachment) { ActiveStorage::Attachment.new }

    let(:key) { described_class::SKIP_METADATA_KEY }

    it 'skips analysis for a blob marked wijaya_skip_analysis' do
      blob = instance_double(ActiveStorage::Blob, metadata: { key => true })
      allow(attachment).to receive(:blob).and_return(blob)

      expect(blob).not_to receive(:analyze_later)
      attachment.send(:analyze_blob_later)
    end

    it 'delegates to normal analysis for an ordinary (non-marked) blob' do
      blob = instance_double(ActiveStorage::Blob, metadata: {}, analyzed?: false)
      allow(attachment).to receive(:blob).and_return(blob)

      expect(blob).to receive(:analyze_later)
      attachment.send(:analyze_blob_later)
    end
  end
end
