# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require Rails.root.join('custom/wijaya/batteries/development_version/hooks')

RSpec.describe Wijaya::Batteries::DevelopmentVersion::Hooks do
  describe '.current_version' do
    it 'returns a valid semantic version' do
      expect(described_class.valid?(described_class.current_version)).to be(true)
    end
  end

  describe '.valid?' do
    it 'accepts MAJOR.MINOR.PATCH' do
      expect(described_class.valid?('0.1.0')).to be(true)
      expect(described_class.valid?('12.34.56')).to be(true)
    end

    it 'rejects malformed versions' do
      expect(described_class.valid?('1.0')).to be(false)
      expect(described_class.valid?('v1.0.0')).to be(false)
      expect(described_class.valid?('1.0.0-beta')).to be(false)
      expect(described_class.valid?('')).to be(false)
    end
  end

  describe '.next_version' do
    it 'bumps patch' do
      expect(described_class.next_version('0.1.0', 'patch')).to eq('0.1.1')
    end

    it 'bumps minor and resets patch' do
      expect(described_class.next_version('0.1.3', 'minor')).to eq('0.2.0')
    end

    it 'bumps major and resets minor/patch' do
      expect(described_class.next_version('1.4.2', 'major')).to eq('2.0.0')
    end

    it 'raises on an invalid current version' do
      expect { described_class.next_version('1.0', 'patch') }.to raise_error(ArgumentError)
    end

    it 'raises on an invalid bump part' do
      expect { described_class.next_version('1.0.0', 'build') }.to raise_error(ArgumentError)
    end
  end

  describe '.write_version! and .prepend_changelog!' do
    it 'writes version.yml and prepends a changelog section using a temp battery copy' do
      Dir.mktmpdir do |dir|
        version_file = File.join(dir, 'version.yml')
        changelog_file = File.join(dir, 'CHANGELOG.md')
        File.write(version_file, "# comment\nversion: 0.1.0\n")
        File.write(changelog_file, "# Changelog\n\n## v0.1.0 - 2026-06-29\n\n- initial\n")

        stub_const("#{described_class}::VERSION_FILE", version_file)
        stub_const("#{described_class}::CHANGELOG_FILE", changelog_file)

        new_version = described_class.next_version(described_class.current_version, 'minor')
        described_class.write_version!(new_version)
        described_class.prepend_changelog!(new_version, 'Add temp feature', date: '2026-06-30')

        expect(described_class.current_version).to eq('0.2.0')
        expect(File.read(version_file)).to include('version: 0.2.0')
        changelog = File.read(changelog_file)
        expect(changelog).to include('## v0.2.0 - 2026-06-30')
        expect(changelog).to include('- Add temp feature')
        expect(changelog.index('v0.2.0')).to be < changelog.index('v0.1.0')
      end
    end
  end
end
