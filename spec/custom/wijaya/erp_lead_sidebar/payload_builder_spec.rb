# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::PayloadBuilder do
  let(:valid_fields) do
    {
      'lead_owner' => 'user@example.com',
      'first_name' => 'Sr Modesta PM',
      'company_name' => '',
      'whatsapp_no' => '+6281238392959',
      'mobile_no' => '+620000000000',
      'status' => 'Lead',
      'utm_source' => 'WhatsApp',
      'industry' => 'Garment',
      'territory' => 'JAWA TENGAH',
      'utm_campaign' => 'Online Store ',
      'custom_online_store' => true,
      'custom_tshirt' => '1',
      'custom_market_customer' => 'must not pass through',
      'custom_jenis_pakaian' => 'must not pass through',
      'campaign_name' => 'must not pass through'
    }
  end

  it 'builds only the frozen ERP Lead payload fields' do
    payload = described_class.new(valid_fields).payload

    expect(payload).to include(
      :doctype => 'Lead',
      'lead_owner' => 'user@example.com',
      'first_name' => 'Sr Modesta PM',
      'whatsapp_no' => '+6281238392959',
      'mobile_no' => '+6281238392959',
      'status' => 'Lead',
      'utm_source' => 'WhatsApp',
      'industry' => 'Garment',
      'territory' => 'JAWA TENGAH',
      'utm_campaign' => 'Online Store ',
      'custom_online_store' => 1,
      'custom_tshirt' => 1
    )
    expect(payload).not_to have_key('custom_market_customer')
    expect(payload).not_to have_key('custom_jenis_pakaian')
    expect(payload).not_to have_key('campaign_name')
  end

  it 'requires industry on dev-tex' do
    expect { described_class.new(valid_fields.merge('industry' => '')).payload }
      .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /industry is required/)
  end

  it 'requires first_name or company_name' do
    expect { described_class.new(valid_fields.merge('first_name' => '', 'company_name' => '')).payload }
      .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /first_name or company_name/)
  end
end
