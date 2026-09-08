# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::ErrorSanitizer do
  # Minimal stand-in for a PG::Error carrying a SQLSTATE via #result.
  def pg_error_with(sqlstate, message)
    result = instance_double(PG::Result)
    allow(result).to receive(:error_field).with(PG::PG_DIAG_SQLSTATE).and_return(sqlstate)
    error = PG::Error.new(message)
    allow(error).to receive(:result).and_return(result)
    error
  end

  it 'passes SanitizedError through unchanged' do
    original = Marine::Provisioning::Errors::AlreadyProvisionedError.new
    expect(described_class.sanitize(original)).to be(original)
  end

  it 'maps insufficient_privilege (42501) to a safe message' do
    sanitized = described_class.sanitize(pg_error_with('42501', 'permission denied for database chatwoot'))
    expect(sanitized).to be_a(Marine::Provisioning::Errors::SanitizedError)
    expect(sanitized.i18n_key).to eq('PROVISIONING.ERRORS.INSUFFICIENT_PRIVILEGE')
    expect(sanitized.message).not_to include('chatwoot')
  end

  it 'never leaks raw SQL / passwords from the underlying error message' do
    raw = "ERROR: syntax error CREATE ROLE app LOGIN PASSWORD 'hunter2'"
    sanitized = described_class.sanitize(pg_error_with('42601', raw))
    expect(sanitized.message).not_to include('hunter2')
    expect(sanitized.message).not_to include('PASSWORD')
    expect(sanitized.i18n_key).to eq('PROVISIONING.ERRORS.GENERIC')
  end

  it 'falls back to a generic sanitized error for non-PG errors' do
    sanitized = described_class.sanitize(RuntimeError.new('kaboom: secret-conn-string'))
    expect(sanitized.i18n_key).to eq('PROVISIONING.ERRORS.GENERIC')
    expect(sanitized.message).not_to include('secret-conn-string')
  end
end
