#!/usr/bin/env ruby
# frozen_string_literal: true

# Bump the Wijaya internal development version (independent of official Chatwoot
# versioning). Updates version.yml and prepends an entry to CHANGELOG.md.
#
# Usage:
#   ruby scripts/bump_version.rb <major|minor|patch> "<changelog entry>"
#   ruby scripts/bump_version.rb <major|minor|patch> "<changelog entry>" --dry-run
#   ruby scripts/bump_version.rb --current
#   ruby scripts/bump_version.rb --help

require_relative '../hooks'

Hooks = Wijaya::Batteries::DevelopmentVersion::Hooks

def usage
  <<~TXT
    Wijaya internal development version bumper

    Usage:
      ruby scripts/bump_version.rb <part> "<changelog entry>" [--dry-run]
      ruby scripts/bump_version.rb --current
      ruby scripts/bump_version.rb --help

    Arguments:
      part              One of: major | minor | patch
      changelog entry   Short description of the change (required unless --dry-run)

    Options:
      --dry-run         Print the old/new version without writing any files
      --current         Print the current version and exit
      --help            Show this help
  TXT
end

args = ARGV.dup

if args.empty? || args.include?('--help') || args.include?('-h')
  puts usage
  exit 0
end

if args.include?('--current')
  puts Hooks.current_version
  exit 0
end

dry_run = args.delete('--dry-run')
part = args.shift
entry = args.shift

unless Hooks::PARTS.include?(part.to_s)
  warn "error: part must be one of #{Hooks::PARTS.join('|')} (got #{part.inspect})"
  warn usage
  exit 1
end

current = Hooks.current_version
new_version =
  begin
    Hooks.next_version(current, part)
  rescue ArgumentError => e
    warn "error: #{e.message}"
    exit 1
  end

if dry_run
  puts "DRY RUN (no files changed)"
  puts "old version: v#{current}"
  puts "new version: v#{new_version}"
  exit 0
end

if entry.to_s.strip.empty?
  warn 'error: a changelog entry is required when not running with --dry-run'
  warn usage
  exit 1
end

Hooks.write_version!(new_version)
Hooks.prepend_changelog!(new_version, entry)

puts "old version: v#{current}"
puts "new version: v#{new_version}"
puts "changelog:   #{Hooks::CHANGELOG_FILE}"
