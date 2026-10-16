require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/proxy_https/policy')

RSpec.describe Wijaya::Batteries::ProxyHttps::Policy do
  subject(:apply_policy) { described_class.apply!(config, env: env) }

  let(:middleware) { instance_double(Rails::Configuration::MiddlewareStackProxy) }
  let(:config) { Struct.new(:force_ssl, :assume_ssl, :middleware).new(nil, nil, middleware) }

  context 'when FORCE_SSL is true' do
    let(:env) { { 'FORCE_SSL' => 'true' } }

    it 'enables HTTPS enforcement with proxy-aware scheme normalization' do
      expect(middleware).to receive(:insert_before)
        .with(0, Wijaya::Batteries::ProxyHttps::ProxySchemeMiddleware).once

      apply_policy
      described_class.apply!(config, env: env)

      expect(config.force_ssl).to be(true)
      expect(config.assume_ssl).to be(false)
    end
  end

  context 'when FORCE_SSL is false' do
    let(:env) { { 'FORCE_SSL' => 'false' } }

    it 'leaves HTTPS enforcement disabled without installing middleware' do
      expect(middleware).not_to receive(:insert_before)

      apply_policy

      expect(config.force_ssl).to be(false)
      expect(config.assume_ssl).to be(false)
    end
  end

  context 'when FORCE_SSL is unset' do
    let(:env) { {} }

    it 'keeps both settings disabled by default' do
      expect(middleware).not_to receive(:insert_before)

      apply_policy

      expect(config.force_ssl).to be(false)
      expect(config.assume_ssl).to be(false)
    end
  end
end
