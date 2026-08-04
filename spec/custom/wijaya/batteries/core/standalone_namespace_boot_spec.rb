# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'tempfile'

# Regression coverage for the collection-time namespace/autoload boot failure.
#
# The Wijaya battery bootstrap files are `require`d directly (NOT via Zeitwerk)
# from config/initializers/wijaya.rb and from native app files, before Zeitwerk
# has autovivified any `Wijaya` parent constant. A RuboCop autocorrection once
# rewrote them into compact form (`module Wijaya::Batteries::Core::Loader`, etc).
# Compact declarations require every parent constant to already exist, so they
# raised `uninitialized constant Wijaya::...` at boot; the initializer rescued it
# and every battery silently stayed unloaded, which surfaced in CI as 16 shards
# loading 0 examples with `NameError: uninitialized constant Marine`.
#
# This spec proves the fix (nested declarations that create each parent on the
# way in) in a genuinely FRESH namespace/load context: a subprocess with a tiny
# `Rails` stub and NO `Wijaya` predefined, requiring the real bootstrap files in
# the same order the initializer/loader does. If any file were compact again, the
# require would raise `uninitialized constant` and the subprocess would fail.
#
# It deliberately does NOT require the battery files from rails_helper or from the
# example itself — that would mask the bug by pre-creating the namespaces.
RSpec.describe 'Wijaya battery standalone namespace boot' do
  # Files that are required directly before their Wijaya parent exists. Order
  # mirrors config/initializers/wijaya.rb -> core loader -> discovered feature
  # loaders, then the hooks native code requires directly.
  BOOTSTRAP_REQUIRES = %w[
    custom/wijaya/batteries/core/loader
    custom/wijaya/batteries/marine_ai/loader
    custom/wijaya/batteries/meta_ads_team_routing/loader
    custom/wijaya/batteries/erp_lead_sidebar/loader
    custom/wijaya/batteries/custom_roles/hooks
    custom/wijaya/batteries/ads_tracking/hooks
    custom/wijaya/batteries/development_version/hooks
  ].freeze

  # Constants that MUST resolve once the bootstrap files above are required. These
  # are exactly the namespaces whose compact declarations broke collection.
  REQUIRED_CONSTANTS = %w[
    Wijaya::Batteries::Core::Loader
    Wijaya::Batteries::Core::Hooks
    Wijaya::Batteries::Routes
    Wijaya::Marine::Loader
    Wijaya::Batteries::MetaAdsTeamRouting::Loader
    Wijaya::Batteries::ErpLeadSidebar::Loader
    Wijaya::Batteries::CustomRoles::Hooks
    Wijaya::Batteries::AdsTracking::Hooks
    Wijaya::Batteries::AdsTracking::ReferralParser
    Wijaya::Batteries::DevelopmentVersion::Hooks
  ].freeze

  # Subset of REQUIRED_CONSTANTS that the initializer -> core loader -> discovered
  # feature loaders path eagerly defines at app boot. The remaining REQUIRED_CONSTANTS
  # (the CustomRoles/AdsTracking/DevelopmentVersion hook + parser namespaces) are
  # required on demand by the native seams that use them (or lazily via constantize
  # in the core dispatcher), so they are NOT guaranteed to be loaded in a freshly
  # booted app and must not be asserted here. The subprocess example above still
  # proves every namespace resolves when its own bootstrap file is required.
  BOOT_LOADED_CONSTANTS = %w[
    Wijaya::Batteries::Core::Loader
    Wijaya::Batteries::Core::Hooks
    Wijaya::Batteries::Routes
    Wijaya::Marine::Loader
    Wijaya::Batteries::MetaAdsTeamRouting::Loader
    Wijaya::Batteries::ErpLeadSidebar::Loader
  ].freeze

  it 'creates every parent namespace from the standalone files with Wijaya undefined at start' do
    script = <<~RUBY
      require 'pathname'

      REPO = Pathname.new(#{Rails.root.to_s.inspect})

      # Minimal Rails stub: the bootstrap files only touch Rails.root at load time
      # (constant assignments) and Rails.logger inside method bodies that never run
      # here. No Rails, ActiveSupport, or database is loaded.
      module Rails
        def self.root = REPO
        def self.logger = nil
        def self.respond_to?(name, include_all = false) = %i[root logger].include?(name) || super
      end

      abort 'FRESH_CONTEXT_VIOLATION: Wijaya must not be predefined' if defined?(Wijaya)

      #{BOOTSTRAP_REQUIRES.map { |rel| "require REPO.join(#{rel.inspect}).to_s" }.join("\n      ")}

      #{REQUIRED_CONSTANTS.map { |c| "Object.const_get(#{c.inspect})" }.join("\n      ")}

      puts 'STANDALONE_BOOT_OK'
    RUBY

    stdout, status =
      Tempfile.create(['wijaya_boot', '.rb']) do |file|
        file.write(script)
        file.flush
        Open3.capture2e(RbConfig.ruby, file.path)
      end

    expect(stdout).to include('STANDALONE_BOOT_OK'), "boot runner failed:\n#{stdout}"
    expect(status).to be_success
  end

  it 'sanity: the boot-loaded namespaces are resolved in the booted test app' do
    BOOT_LOADED_CONSTANTS.each do |const_name|
      expect { Object.const_get(const_name) }.not_to raise_error, "#{const_name} did not resolve in the booted app"
    end
  end
end
