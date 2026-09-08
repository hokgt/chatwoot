# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the Marine::Catalog autoload / namespace-resolution bug, mirroring the
# documents/ and provisioning/ namespace_resolution specs.
#
# Every class/module under marine_ai/app/services/marine/catalog references sibling constants
# (Errors, Config, ReplyRenderer, IntentExtractor, Connection, the repositories, ...). Resolving
# those UNQUALIFIED references depends on Marine::Catalog staying on the lexical lookup path — the
# nested `module Marine; module Catalog; ...` declaration — so Zeitwerk can autoload the sibling on
# demand. A compact `class Marine::Catalog::X` autocorrection drops Marine::Catalog off the nesting
# and each sibling raises NameError.
#
# Separately, with config.cache_classes = false a Rails code reload swaps the Marine::Catalog
# module object; a reference captured before the reload (rspec's memoized described_class) is left
# pointing at the orphaned namespace, and unqualified sibling refs inside it then raised
# `uninitialized constant Marine::Catalog::Connection::Errors` (and siblings) — the exact shard-9
# CE failure. The reload-reached call sites in connection.rb / product_query_orchestrator.rb /
# product_flow_state_store.rb therefore fully qualify those refs so they resolve against the
# always-current top-level Marine constant. This spec references every constant fully qualified, so
# it stays correct regardless of reload timing.
RSpec.describe 'Marine::Catalog namespace resolution' do
  CATALOG_SERVICE_CONSTANTS = %w[
    Config Connection Errors FactPlaceholderMask GroundedHandoffWordingService
    GroundedProductWordingService IntentExtractor PlanBuilder PlaygroundPreview
    PlaygroundStateToken PriceRepository ProductFactProtectionValidator
    ProductFamilyRepository ProductFlowStateStore ProductQueryOrchestrator
    ReplyLocalizer ReplyPresenter ReplyRenderer StockReplyComposer StockRepository
    VariantRepository VariantResolver
  ].freeze

  describe 'autoloading each catalog service' do
    CATALOG_SERVICE_CONSTANTS.each do |short_name|
      it "loads Marine::Catalog::#{short_name} without raising on sibling lookup" do
        expect { "Marine::Catalog::#{short_name}".constantize }.not_to raise_error
      end
    end
  end

  describe 'unqualified sibling constants resolve at runtime' do
    it 'reaches Connection#select -> Errors::CatalogUnavailableError on a non-SELECT' do
      expect { Marine::Catalog::Connection.select('DROP TABLE anything') }
        .to raise_error(Marine::Catalog::Errors::CatalogUnavailableError)
    end

    it 'reaches ProductQueryOrchestrator -> ReplyRenderer / IntentExtractor on construction' do
      orchestrator = Marine::Catalog::ProductQueryOrchestrator.new
      expect(orchestrator.send(:intent_extractor)).to be_a(Marine::Catalog::IntentExtractor)
    end

    it 'exposes ProductFlowStateStore -> IntentExtractor::SUPPORTED_PRODUCT_INTENTS' do
      expect(Marine::Catalog::IntentExtractor::SUPPORTED_PRODUCT_INTENTS).to be_an(Array)
    end
  end
end
