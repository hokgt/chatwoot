# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::HostValidator do
  describe '.normalize' do
    it 'trims whitespace and strips a trailing slash' do
      expect(described_class.normalize('  https://erp.example.com/  ')).to eq('https://erp.example.com')
    end
  end

  describe '.error_for' do
    it 'accepts a plain https origin' do
      expect(described_class.error_for('https://erp.example.com')).to be_nil
    end

    it 'accepts an https origin with a port' do
      expect(described_class.error_for('https://erp.example.com:8443')).to be_nil
    end

    it 'accepts http for localhost' do
      expect(described_class.error_for('http://localhost:8000')).to be_nil
    end

    it 'rejects http for a private-range host' do
      expect(described_class.error_for('http://192.168.1.10')).to eq('must use HTTPS')
    end

    it 'rejects http for a public host' do
      expect(described_class.error_for('http://erp.example.com')).to eq('must use HTTPS')
    end

    it 'rejects embedded credentials' do
      expect(described_class.error_for('https://user:pass@erp.example.com')).to eq('must not include embedded credentials')
    end

    it 'rejects a URL carrying a path' do
      expect(described_class.error_for('https://erp.example.com/api/resource')).to eq('must be an origin only (no path, query, or fragment)')
    end

    it 'rejects a URL carrying a query' do
      expect(described_class.error_for('https://erp.example.com?token=x')).to eq('must be an origin only (no path, query, or fragment)')
    end

    it 'rejects a URL carrying a fragment' do
      expect(described_class.error_for('https://erp.example.com#frag')).to eq('must be an origin only (no path, query, or fragment)')
    end

    it 'rejects a non-http(s) scheme' do
      expect(described_class.error_for('ftp://erp.example.com')).to eq('is not a valid URL')
    end

    it 'rejects a blank/garbage value' do
      expect(described_class.error_for('not a url')).to eq('is not a valid URL')
    end
  end

  describe '.safe_remote_uri?' do
    it 'allows an explicit localhost target' do
      expect(described_class.safe_remote_uri?(URI.parse('http://localhost:8000/api'))).to be(true)
    end

    it 'allows a public host that resolves to public IPs' do
      allow(described_class).to receive(:resolve).and_return(['93.184.216.34'])
      expect(described_class.safe_remote_uri?(URI.parse('https://erp.example.com/api'))).to be(true)
    end

    it 'blocks a public host that resolves to a loopback IP (DNS rebinding)' do
      allow(described_class).to receive(:resolve).and_return(['127.0.0.1'])
      expect(described_class.safe_remote_uri?(URI.parse('https://rebind.example.com/api'))).to be(false)
    end

    it 'blocks a public host that resolves to a private IP' do
      allow(described_class).to receive(:resolve).and_return(['10.0.0.5'])
      expect(described_class.safe_remote_uri?(URI.parse('https://rebind.example.com/api'))).to be(false)
    end

    it 'blocks a literal link-local metadata address' do
      expect(described_class.safe_remote_uri?(URI.parse('https://169.254.169.254/api'))).to be(false)
    end

    it 'blocks a host that does not resolve at all' do
      allow(described_class).to receive(:resolve).and_return([])
      expect(described_class.safe_remote_uri?(URI.parse('https://nxdomain.example.com/api'))).to be(false)
    end
  end
end
