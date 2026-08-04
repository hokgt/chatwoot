# frozen_string_literal: true

require 'rails_helper'

# Lexical-namespace regression guard for the Marine catalog / documents service
# families.
#
# These classes/modules deliberately use NESTED declarations
# (`module Marine; module Catalog; class ...`) so that the shared parent
# namespaces stay on Ruby's constant-lookup path (Module.nesting) and bare
# sibling references — `Config`, `Connection`, `Errors`, `CommandRunner`,
# `UploadValidator` — resolve to `Marine::Catalog::*` / `Marine::Documents::*`.
#
# A RuboCop `Style/ClassAndModuleChildren` autocorrection previously collapsed
# them to the compact form `class Marine::Catalog::ProductFamilyRepository`, which
# drops `Marine::Catalog` from the nesting and raised, at runtime, e.g.
# `uninitialized constant Marine::Catalog::ProductFamilyRepository::Config` and
# `uninitialized constant Marine::Documents::Sop::ExtractionService::CommandRunner`.
#
# Each example drives a code path that dereferences a bare sibling constant and
# asserts the intended sanitized Marine error is raised — NOT a NameError. If the
# nesting regresses, these fail with NameError instead of the expected error. All
# examples are hermetic: no live catalog/application database is touched.
RSpec.describe 'Marine namespace lexical resolution' do
  describe Marine::Catalog::ProductFamilyRepository do
    it 'resolves bare Config and Errors from within the repository (fails closed, not NameError)' do
      allow(Marine::Catalog::Config).to receive(:configured?).and_return(false)

      expect { described_class.new.exists?('HULL-9000') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
      expect { described_class.new.search(query: 'x') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end

  describe Marine::Catalog::Connection do
    it 'resolves bare Errors when rejecting a non-SELECT statement (no DB connection)' do
      expect { described_class.select('DELETE FROM item') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end
  end

  describe Marine::Documents::UploadValidator do
    it 'resolves bare Errors when rejecting a non-upload argument' do
      expect { described_class.new(nil).call }
        .to raise_error(Marine::Documents::Errors::InvalidFileError)
    end
  end

  describe Marine::Documents::Sop::ExtractionService do
    it 'resolves bare CommandRunner and Errors from the parent Documents namespace' do
      blob = instance_double(ActiveStorage::Blob, content_type: 'text/plain')
      allow(blob).to receive(:download).and_yield('irrelevant'.b)

      # Unsupported content type reaches the dispatch `else` branch, which raises
      # `Errors::SopExtractionFailedError` — but only after `CommandRunner.open`
      # (a bare parent-namespace reference) has already resolved and run.
      expect { described_class.new(blob: blob).call }
        .to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
    end
  end

  describe Marine::Documents::ProcessJob do
    # ProcessJob#process dispatches through the bare sibling `Sop::ExtractionService`.
    # Under the compact `class Marine::Documents::ProcessJob` declaration that constant
    # does NOT resolve (NameError), and the job's `rescue StandardError` silently marks
    # the document failed with nil content. This asserts the bare sibling still resolves:
    # a stubbed service on the fully-qualified constant must actually be invoked, proving
    # `Sop::ExtractionService` and `Marine::Documents::Sop::ExtractionService` are the
    # same constant (i.e. Marine::Documents is still on the lexical lookup path).
    it 'resolves the bare Sop::ExtractionService sibling to the fully-qualified constant' do
      result = Marine::Documents::Sop::ExtractionService::Result.new(
        content: 'body', processing_method: 'pdf_text', page_count: 1
      )
      service = instance_double(Marine::Documents::Sop::ExtractionService, call: result)
      expect(Marine::Documents::Sop::ExtractionService).to receive(:new).and_return(service)

      account = create(:account)
      assistant = create(:marine_assistant, account: account)
      document = create(:marine_document, :sop_document, assistant: assistant,
                                                         status: :in_progress, sync_status: :syncing, content: nil)

      described_class.perform_now(document)

      expect(document.reload.content).to eq('body')
    end
  end
end
