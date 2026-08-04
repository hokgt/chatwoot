# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::Audit do
  # Capture exactly what is handed to the logger so we can assert on the serialized
  # audit line rather than mocking internals.
  def logged_line
    captured = nil
    allow(Rails.logger).to receive(:info) { |line| captured = line }
    yield
    captured
  end

  describe 'target value sanitization' do
    it 'retains valid identifiers, statuses, and privilege levels' do
      line = logged_line do
        described_class.record(
          action: 'provision.create',
          target: { database_name: 'marine_erp', login_username: 'marine_app', privilege_level: 'writer', status: 'active' }
        )
      end
      target = JSON.parse(line)['target']

      expect(target).to eq(
        'database_name' => 'marine_erp',
        'login_username' => 'marine_app',
        'privilege_level' => 'writer',
        'status' => 'active'
      )
    end

    it 'replaces an oversized identifier with the fixed marker (never logged raw)' do
      oversized = 'a' * 200
      line = logged_line do
        described_class.record(action: 'provision.create', target: { database_name: oversized })
      end

      expect(line).not_to include(oversized)
      expect(JSON.parse(line)['target']['database_name']).to eq('[invalid]')
    end

    it 'replaces a value containing control characters with the fixed marker' do
      malicious = "marine\u0000erp\ndrop"
      line = logged_line do
        described_class.record(action: 'provision.create', target: { login_username: malicious })
      end

      expect(line).not_to include('drop')
      expect(JSON.parse(line)['target']['login_username']).to eq('[invalid]')
    end

    it 'replaces a secret-looking / quoted injection value with the fixed marker' do
      secret = "'; GRANT ALL --"
      line = logged_line do
        described_class.record(action: 'provision.create', target: { owner_role: secret })
      end

      expect(line).not_to include('GRANT ALL')
      expect(JSON.parse(line)['target']['owner_role']).to eq('[invalid]')
    end

    it 'replaces an unknown status/privilege value with the fixed marker' do
      line = logged_line do
        described_class.record(action: 'provision.create', target: { status: 'pwned', privilege_level: 'superuser' })
      end
      target = JSON.parse(line)['target']

      expect(target['status']).to eq('[invalid]')
      expect(target['privilege_level']).to eq('[invalid]')
    end

    it 'rejects a raw String target entirely (renders no target key)' do
      line = logged_line do
        described_class.record(action: 'provision.create', target: 'arbitrary secret string')
      end

      expect(line).not_to include('arbitrary secret string')
      expect(JSON.parse(line)).not_to have_key('target')
    end
  end
end
