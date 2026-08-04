# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::Connection do
  describe '.app_connectivity_ok?' do
    let(:conn) { instance_double(PG::Connection) }
    let(:app_params) do
      {
        dbname: 'chatwoot_prod',
        user: 'chatwoot',
        password: 'app-secret',
        host: 'app-db.internal',
        port: 6543,
        sslmode: 'require',
        connect_timeout: 5
      }
    end

    before do
      allow(Marine::Provisioning::Config).to receive(:app_connection_params).and_return(app_params)
      allow(conn).to receive(:exec).with('SELECT 1')
      allow(conn).to receive(:close)
    end

    it 'connects to the app endpoint (not the provisioning admin host) and closes' do
      captured = nil
      allow(PG).to receive(:connect) do |**kwargs|
        captured = kwargs
        conn
      end

      expect(described_class.app_connectivity_ok?).to be(true)

      expect(captured).to eq(app_params)
      expect(captured[:host]).to eq('app-db.internal')
      expect(captured[:sslmode]).to eq('require')
      # Provisioning admin host/port/sslmode must never be substituted here.
      expect(captured[:host]).not_to eq(Marine::Provisioning::Config.admin_host)
      expect(conn).to have_received(:exec).with('SELECT 1')
      expect(conn).to have_received(:close)
    end

    it 'returns false and never raises PG details when the connection fails' do
      allow(PG).to receive(:connect).and_raise(PG::ConnectionBad.new('FATAL: password authentication failed'))

      expect(described_class.app_connectivity_ok?).to be(false)
    end
  end
end
