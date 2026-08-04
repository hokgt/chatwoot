# frozen_string_literal: true

require 'rails_helper'

# Regression guard for the RuboCop compact-declaration namespace bug.
#
# Every class/module under marine_ai/app/services/marine/provisioning references
# unqualified sibling constants (StateStore, Config, PrivilegeService, ...). Those
# resolve ONLY when the files keep nested `module Marine; module Provisioning; ...`
# declarations so Marine::Provisioning stays on the lexical lookup path. When the
# compact form `class Marine::Provisioning::X` was autocorrected in, Ruby dropped
# Marine::Provisioning from the nesting and each sibling raised NameError at
# autoload time — surfacing as `bundle exec rspec --dry-run` collection errors.
RSpec.describe 'Marine::Provisioning namespace resolution' do
  SERVICE_CONSTANTS = %w[
    Audit
    CatalogService
    Config
    Connection
    ErrorSanitizer
    Errors
    IdentifierValidator
    PrivilegeService
    ProvisionService
    StateStore
  ].freeze

  describe 'autoloading each provisioning service' do
    SERVICE_CONSTANTS.each do |short_name|
      it "loads Marine::Provisioning::#{short_name} without raising on sibling lookup" do
        expect { "Marine::Provisioning::#{short_name}".constantize }.not_to raise_error
      end
    end
  end

  describe 'sibling constants resolve through the shared lexical scope' do
    # Audit builds ALLOWED_STATUSES from StateStore at class-body evaluation time,
    # so this only exists if the unqualified StateStore sibling resolved on load.
    it 'resolves StateStore from within Audit' do
      expect(Marine::Provisioning::Audit::ALLOWED_STATUSES)
        .to include(Marine::Provisioning::StateStore::STATUS_ACTIVE)
    end

    # CatalogService sets TARGET_SCHEMA = PrivilegeService::TARGET_SCHEMA on load.
    it 'resolves PrivilegeService from within CatalogService' do
      expect(Marine::Provisioning::CatalogService::TARGET_SCHEMA)
        .to eq(Marine::Provisioning::PrivilegeService::TARGET_SCHEMA)
    end

    # PrivilegeService sets TARGET_SCHEMA = Config::PROJECTION_SCHEMA on load.
    it 'resolves Config from within PrivilegeService' do
      expect(Marine::Provisioning::PrivilegeService::TARGET_SCHEMA)
        .to eq(Marine::Provisioning::Config::PROJECTION_SCHEMA)
    end
  end
end
