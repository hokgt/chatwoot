require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/proxy_https/policy')

RSpec.describe Wijaya::Batteries::ProxyHttps::Policy do
  subject(:apply_policy) { described_class.apply!(config, env: env) }

  let(:config) { Struct.new(:force_ssl, :assume_ssl).new }

  context 'when FORCE_SSL is true' do
    let(:env) { { 'FORCE_SSL' => 'true' } }

    it 'enables HTTPS enforcement and trusted-proxy SSL assumption' do
      apply_policy

      expect(config.force_ssl).to be(true)
      expect(config.assume_ssl).to be(true)
    end
  end

  context 'when FORCE_SSL is false' do
    let(:env) { { 'FORCE_SSL' => 'false' } }

    it 'disables HTTPS enforcement without unexpectedly assuming SSL' do
      apply_policy

      expect(config.force_ssl).to be(false)
      expect(config.assume_ssl).to be(false)
    end
  end

  context 'when FORCE_SSL is unset' do
    let(:env) { {} }

    it 'keeps both settings disabled by default' do
      apply_policy

      expect(config.force_ssl).to be(false)
      expect(config.assume_ssl).to be(false)
    end
  end
end
