# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::IdentifierValidator do
  describe '.validate!' do
    it 'accepts a valid lowercase identifier' do
      expect(described_class.validate!('marine_erp', label: 'Database name')).to eq('marine_erp')
    end

    it 'rejects a blank value' do
      expect { described_class.validate!('  ', label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects values longer than 63 bytes' do
      expect { described_class.validate!('a' * 64, label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects uppercase / illegal characters (would require quoting)' do
      expect { described_class.validate!('Marine-ERP', label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects names starting with a digit' do
      expect { described_class.validate!('1marine', label: 'Database name') }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'rejects reserved / system names' do
      %w[postgres public template1 pg_catalog pg_toast_temp information_schema].each do |name|
        expect { described_class.validate!(name, label: 'Database name') }
          .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
      end
    end

    it 'rejects the current Chatwoot database and role names via extra_reserved' do
      expect { described_class.validate!('chatwoot_prod', label: 'Database name', extra_reserved: %w[chatwoot_prod]) }
        .to raise_error(Marine::Provisioning::Errors::InvalidIdentifierError)
    end

    it 'never includes the raw offending value in the error message' do
      described_class.validate!('DROP TABLE users', label: 'Database name')
    rescue Marine::Provisioning::Errors::InvalidIdentifierError => e
      expect(e.message).not_to include('DROP TABLE users')
      expect(e.i18n_key).to eq('PROVISIONING.ERRORS.INVALID_IDENTIFIER')
    end
  end

  # Regression: with cache_classes/eager_load off, a captured (stale) reference to the
  # validator can outlive a Rails reload that swaps the Marine::Provisioning namespace.
  # If the error is referenced un-qualified, resolution runs against the stale namespace
  # (whose sibling constants Zeitwerk has removed) and raises NameError instead of the
  # intended InvalidIdentifierError. Fully-qualifying both the raise and the rescue keeps
  # a stale reference correct after a reload.
  describe 'stale reference after Rails reload' do
    # Rails.application.reloader.reload! swaps the whole Marine::Provisioning subtree and
    # mutates global autoloader/constant state, which would otherwise leak into sibling
    # examples. Run the reload inside a forked child so the parent's Zeitwerk bookkeeping
    # is never touched; the child reports the outcome purely via its exit status.
    it 'still raises InvalidIdentifierError, not NameError, from a stale reference' do
      skip 'fork-based isolation requires a platform with fork' unless Process.respond_to?(:fork)

      reader, writer = IO.pipe

      pid = fork do
        reader.close
        outcome =
          begin
            stale_validator = described_class
            Rails.application.reloader.reload!

            stale_validator.validate!('Bad-Name', label: 'Database name')
            'no-error-raised'
          rescue Marine::Provisioning::Errors::InvalidIdentifierError
            # Also exercise the rescue path in .valid? against the reloaded namespace.
            stale_validator.valid?('Bad-Name') == false ? 'ok' : 'valid?-not-false'
          rescue NameError => e
            "name-error: #{e.message}"
          rescue Exception => e # rubocop:disable Lint/RescueException
            "unexpected: #{e.class}: #{e.message}"
          end
        writer.write(outcome)
        writer.close
        # exit! bypasses at_exit hooks (RSpec/SimpleCov) so the child never re-runs the suite.
        exit!(outcome == 'ok' ? 0 : 1) # rubocop:disable Rails/Exit
      end

      writer.close
      outcome = reader.read
      reader.close
      _, status = Process.wait2(pid)

      expect(outcome).to eq('ok')
      expect(status.exitstatus).to eq(0)
    end
  end
end
