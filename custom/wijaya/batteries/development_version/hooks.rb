# frozen_string_literal: true

require 'yaml'
require 'date'

module Wijaya
  module Batteries
    module DevelopmentVersion
      # Wijaya internal development version battery.
      #
      # Versioning is independent of official Chatwoot versioning. The current
      # version is stored in version.yml and human-readable history in
      # CHANGELOG.md. Bumping is performed through scripts/bump_version.rb, which
      # relies on the pure helpers defined here.
      module Hooks
        SEMVER_REGEX = /\A(\d+)\.(\d+)\.(\d+)\z/
        PARTS = %w[major minor patch].freeze
        FALLBACK_VERSION = '0.1.0'

        VERSION_FILE = File.expand_path('version.yml', __dir__)
        CHANGELOG_FILE = File.expand_path('CHANGELOG.md', __dir__)

        module_function

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
        def prepend_changelog!(new_version, entry, date: Date.today.iso8601)
          header = "## v#{new_version} - #{date}\n\n- #{entry.to_s.strip}\n"
          existing = File.exist?(CHANGELOG_FILE) ? File.read(CHANGELOG_FILE) : ''

          marker = existing.index("\n## ")
          if marker
            updated = "#{existing[0...marker + 1]}#{header}\n#{existing[(marker + 1)..]}"
          else
            updated = existing.empty? ? "#{header}" : "#{existing.rstrip}\n\n#{header}"
          end
          File.write(CHANGELOG_FILE, updated)
        end
      end
    end
  end
end
