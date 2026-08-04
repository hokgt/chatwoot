# frozen_string_literal: true

require 'yaml'
require 'date'

# Wijaya internal development version battery.
#
# Versioning is independent of official Chatwoot versioning. The current
# version is stored in version.yml and human-readable history in
# CHANGELOG.md. Bumping is performed through scripts/bump_version.rb, which
# relies on the pure helpers defined here.
# Nested (not compact `module Wijaya::Batteries::DevelopmentVersion::Hooks`) so
# this file is standalone-safe: it is required directly (by specs and resolved via
# constantize from the core dispatcher) with no loader creating its namespace, so
# this nested declaration is the sole creator of DevelopmentVersion; a compact form
# raises `uninitialized constant Wijaya::Batteries::DevelopmentVersion`.
module Wijaya
  module Batteries
    module DevelopmentVersion
      module Hooks
        SEMVER_REGEX = /\A(\d+)\.(\d+)\.(\d+)\z/
        PARTS = %w[major minor patch].freeze
        FALLBACK_VERSION = '0.1.0'

        VERSION_FILE = File.expand_path('version.yml', __dir__)
        CHANGELOG_FILE = File.expand_path('CHANGELOG.md', __dir__)

        module_function

        # Generic dashboard app-config enrichment hook. Merges the internal dev
        # version into the native app_config hash. current_version never raises
        # (falls back), and the core dispatcher returns the original config on any
        # error, so the dashboard config always renders.
        def enrich_app_config(config:)
          config.merge(WIJAYA_DEV_VERSION: current_version)
        end

        # Reads the current internal dev version from version.yml.
        # Returns the fallback version if the file is missing/unreadable so the
        # dashboard never breaks because of a versioning issue.
        def current_version
          data = YAML.safe_load(File.read(VERSION_FILE)) || {}
          version = data['version'].to_s.strip
          valid?(version) ? version : FALLBACK_VERSION
        rescue StandardError
          FALLBACK_VERSION
        end

        def valid?(version)
          version.to_s.match?(SEMVER_REGEX)
        end

        # Computes the next version string given a part to bump.
        # Pure function: does not touch the filesystem.
        def next_version(current, part)
          match = current.to_s.match(SEMVER_REGEX)
          raise ArgumentError, "invalid semantic version: #{current.inspect}" unless match
          raise ArgumentError, "invalid bump part: #{part.inspect} (use #{PARTS.join('|')})" unless PARTS.include?(part.to_s)

          major, minor, patch = match.captures.map(&:to_i)
          case part.to_s
          when 'major' then "#{major + 1}.0.0"
          when 'minor' then "#{major}.#{minor + 1}.0"
          when 'patch' then "#{major}.#{minor}.#{patch + 1}"
          end
        end

        # Writes a new version to version.yml, preserving the leading comment.
        def write_version!(new_version)
          raise ArgumentError, "invalid semantic version: #{new_version.inspect}" unless valid?(new_version)

          lines = File.exist?(VERSION_FILE) ? File.readlines(VERSION_FILE) : []
          comments = lines.take_while { |line| line.start_with?('#') }
          File.write(VERSION_FILE, "#{comments.join}version: #{new_version}\n")
        end

        # Prepends a changelog section for the new version.
        # Changelog stamp is a plain wall-clock date; this dev tool runs outside app request/Time.zone context.
        def prepend_changelog!(new_version, entry, date: Date.today.iso8601) # rubocop:disable Rails/Date
          header = "## v#{new_version} - #{date}\n\n- #{entry.to_s.strip}\n"
          existing = File.exist?(CHANGELOG_FILE) ? File.read(CHANGELOG_FILE) : ''

          marker = existing.index("\n## ")
          updated = if marker
                      "#{existing[0...marker + 1]}#{header}\n#{existing[(marker + 1)..]}"
                    else
                      existing.empty? ? header.to_s : "#{existing.rstrip}\n\n#{header}"
                    end
          File.write(CHANGELOG_FILE, updated)
        end
      end
    end
  end
end
