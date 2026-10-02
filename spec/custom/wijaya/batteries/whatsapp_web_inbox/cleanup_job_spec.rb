# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::CleanupJob do
  let(:client_klass) { Wijaya::Batteries::WhatsappWebInbox::ConnectorClient }
  let(:client) { instance_double(client_klass) }

  it 'deletes the connector session idempotently' do
    allow(client_klass).to receive(:new).and_return(client)
    allow(client).to receive(:delete_session)

    described_class.new.perform(connector_session_id: 'sess-1')
    expect(client).to have_received(:delete_session).with('sess-1')
  end

  it 'is a no-op for a blank session id (never touches the connector)' do
    allow(client_klass).to receive(:new)
    described_class.new.perform(connector_session_id: '')
    expect(client_klass).not_to have_received(:new)
  end

  it 'swallows an already-gone/invalid session (ConnectorError) so it never retries forever' do
    allow(client_klass).to receive(:new).and_return(client)
    allow(client).to receive(:delete_session).and_raise(client_klass::ConnectorError)

    expect { described_class.new.perform(connector_session_id: 'sess-1') }.not_to raise_error
  end

  it 'swallows an unconfigured connector (ConfigurationError)' do
    allow(client_klass).to receive(:new).and_raise(client_klass::ConfigurationError)
    expect { described_class.new.perform(connector_session_id: 'sess-1') }.not_to raise_error
  end

  it 're-raises ConnectorUnavailable so ActiveJob retries (remote never blocks local deletion)' do
    allow(client_klass).to receive(:new).and_return(client)
    allow(client).to receive(:delete_session).and_raise(client_klass::ConnectorUnavailable)

    expect { described_class.new.perform(connector_session_id: 'sess-1') }
      .to raise_error(client_klass::ConnectorUnavailable)
  end
end
