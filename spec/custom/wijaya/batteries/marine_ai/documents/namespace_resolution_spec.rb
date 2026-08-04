# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the RuboCop compact-declaration / cold-order autoload bug,
# mirroring provisioning/namespace_resolution_spec.rb for the Marine::Documents tree.
#
# Marine::Documents::ProductCatalogService references its sibling UploadValidator
# UNQUALIFIED inside #call. That resolves ONLY while the file keeps its nested
# `module Marine; module Documents; class ProductCatalogService` declaration, which
# keeps Marine::Documents on the lexical lookup path so Zeitwerk can autoload the
# sibling on demand. When the compact form `class Marine::Documents::ProductCatalogService`
# was autocorrected in, Marine::Documents dropped off Module.nesting and the runtime
# reference raised `NameError: uninitialized constant
# Marine::Documents::ProductCatalogService::UploadValidator` — one of the exact CI
# collection/runtime failures. Unlike provisioning, ProductCatalogService has NO
# load-time sibling reference, so merely constantizing it does not exercise the path;
# the runtime example below does.
RSpec.describe 'Marine::Documents namespace resolution' do
  DOCUMENTS_SERVICE_CONSTANTS = %w[
    CommandRunner
    CreateSopService
    Errors
    ProductCatalogService
    Serializer
    SyncService
    UploadValidator
  ].freeze

  describe 'autoloading each documents service' do
    DOCUMENTS_SERVICE_CONSTANTS.each do |short_name|
      it "loads Marine::Documents::#{short_name} without raising on sibling lookup" do
        expect { "Marine::Documents::#{short_name}".constantize }.not_to raise_error
      end
    end
  end

  describe 'runtime sibling lookup through the shared lexical scope' do
    # Reaching ProductCatalogService#call line `UploadValidator.new(@upload).call`
    # resolves the unqualified sibling via the Marine::Documents lexical scope. An
    # empty upload makes the (now resolved) validator raise its own InvalidFileError,
    # proving the constant resolved rather than raising NameError. A compact
    # ProductCatalogService declaration would raise NameError here instead.
    it 'resolves UploadValidator from within ProductCatalogService#call' do
      service = Marine::Documents::ProductCatalogService.new(
        account: nil, assistant: nil, product_family_code: 'x', upload: StringIO.new('')
      )
      allow(service).to receive_messages(ensure_account_scope!: nil, ensure_primary_intent!: nil)

      expect { service.call }.to raise_error(Marine::Documents::Errors::InvalidFileError)
    end
  end
end
