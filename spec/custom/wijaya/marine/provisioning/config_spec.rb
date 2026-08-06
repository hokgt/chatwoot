# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Provisioning::Config do
  describe '.bootstrap_password' do
    it 'reads the credential from the mounted secret file' do
      Tempfile.create('marine_secret') do |file|
        file.write("super-secret-bootstrap\n")
        file.flush

        with_modified_env MARINE_PROVISIONING_PG_PASSWORD_FILE: file.path do
          expect(described_class.bootstrap_password).to eq('super-secret-bootstrap')
        end
      end
    end

    it 'fails closed when the path is not configured' do
      with_modified_env MARINE_PROVISIONING_PG_PASSWORD_FILE: nil do
        expect { described_class.bootstrap_password }
          .to raise_error(Marine::Provisioning::Errors::CredentialUnavailableError)
      end
    end

    it 'fails closed when the file is empty' do
      Tempfile.create('marine_secret') do |file|
        with_modified_env MARINE_PROVISIONING_PG_PASSWORD_FILE: file.path do
          expect { described_class.bootstrap_password }
            .to raise_error(Marine::Provisioning::Errors::CredentialUnavailableError)
        end
      end
    end

    it 'fails closed when the file is missing without leaking the path' do
      with_modified_env MARINE_PROVISIONING_PG_PASSWORD_FILE: '/nonexistent/marine_secret' do
        expect { described_class.bootstrap_password }
          .to raise_error(Marine::Provisioning::Errors::CredentialUnavailableError) do |error|
            expect(error.message).not_to include('/nonexistent/marine_secret')
          end
      end
    end
  end

  describe '.configured?' do
    it 'is false without an admin user and secret file' do
      with_modified_env MARINE_PROVISIONING_PG_PASSWORD_FILE: nil, MARINE_PROVISIONING_PG_ADMIN_USER: nil do
        expect(described_class.configured?).to be(false)
      end
    end
  end

  describe '.public_connection_details' do
    it 'never includes a password' do
      expect(described_class.public_connection_details.keys).to contain_exactly(:host, :port, :maintenance_db, :ssl_mode)
    end
  end

  describe '.app_connection_params' do
    before do
      allow(described_class).to receive(:app_db_config).and_return(app_db_config)
    end

    let(:app_db_config) do
      {
        database: 'chatwoot_prod',
        username: 'chatwoot',
        password: 'app-secret',
        host: 'app-db.internal',
        port: 6543,
        sslmode: 'require',
        sslrootcert: '/certs/ca.crt'
      }
    end

    it 'reproduces the app endpoint using libpq keys mapped from the AR config' do
      params = described_class.app_connection_params

      expect(params).to include(
        dbname: 'chatwoot_prod',
        user: 'chatwoot',
        host: 'app-db.internal',
        port: 6543,
        sslmode: 'require',
        sslrootcert: '/certs/ca.crt',
        connect_timeout: Marine::Provisioning::Config::CONNECT_TIMEOUT
      )
    end

    it 'never substitutes the provisioning admin host/port/sslmode' do
      with_modified_env MARINE_PROVISIONING_PG_HOST: 'admin-db.internal', MARINE_PROVISIONING_PG_PORT: '5555',
                        MARINE_PROVISIONING_PG_SSLMODE: 'disable' do
        params = described_class.app_connection_params

        expect(params[:host]).to eq('app-db.internal')
        expect(params[:sslmode]).to eq('require')
      end
    end

    it 'omits blank keys so Unix-socket/default resolution still works' do
      allow(described_class).to receive(:app_db_config).and_return(
        database: 'chatwoot_prod', username: 'chatwoot', password: '', host: '', port: nil
      )

      params = described_class.app_connection_params

      expect(params).to include(dbname: 'chatwoot_prod', user: 'chatwoot')
      expect(params).not_to have_key(:host)
      expect(params).not_to have_key(:port)
      expect(params).not_to have_key(:password)
    end
  end
end
