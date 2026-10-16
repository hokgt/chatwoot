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

  # The sidebar full Lead payload must NEVER carry an owner: the ERP Lead owner is set
  # exclusively post-link by the erp_lead_owner_sync battery from the validated assignee
  # email. Even a lead_owner present in the draft fields (legacy/untrusted) is dropped.
  it 'never emits lead_owner even when the draft fields carry one' do
    payload = described_class.new(valid_fields.merge('lead_owner' => 'attacker@evil.example')).payload

    expect(payload).not_to have_key('lead_owner')
  end

  it 'accepts every current status value' do
    Wijaya::Batteries::ErpLeadSidebar::Config::STATUS_VALUES.each do |status|
      payload = described_class.new(valid_fields.merge('status' => status)).payload
      expect(payload['status']).to eq(status)
    end
  end

  it 'rejects removed legacy status values' do
    %w[Open Opportunity].each do |status|
      expect { described_class.new(valid_fields.merge('status' => status)).payload }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /status is not allowed/)
    end
  end

  it 'requires industry on dev-tex' do
    expect { described_class.new(valid_fields.merge('industry' => '')).payload }
      .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /industry is required/)
  end

  it 'requires first_name or company_name' do
    expect { described_class.new(valid_fields.merge('first_name' => '', 'company_name' => '')).payload }
      .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /first_name or company_name/)
  end

  describe 'Requirements fields' do
    it 'keeps product_requirements as a multiline string (unchanged)' do
      multiline = "Line one\nLine two\nLine three"
      payload = described_class.new(valid_fields.merge('product_requirements' => multiline)).payload

      expect(payload['product_requirements']).to eq(multiline)
    end

    # product_requirement is a Table MultiSelect: an ordered array of unique names is
    # sent as child rows [{ product_requirement: name }, ...].
    it 'builds ordered Table MultiSelect child rows from an array of names' do
      payload = described_class.new(
        valid_fields.merge('product_requirement' => ['rayon twill biru muda', 'rayon twill'])
      ).payload

      expect(payload['product_requirement']).to eq(
        [{ 'product_requirement' => 'rayon twill biru muda' }, { 'product_requirement' => 'rayon twill' }]
      )
    end

    # Backward compatibility: a legacy scalar Link string normalizes to one row.
    it 'normalizes a legacy scalar string into a single canonical row' do
      payload = described_class.new(valid_fields.merge('product_requirement' => 'LPR-0001')).payload

      expect(payload['product_requirement']).to eq([{ 'product_requirement' => 'LPR-0001' }])
    end

    it 'drops blanks and duplicates while preserving order' do
      payload = described_class.new(
        valid_fields.merge('product_requirement' => ['rayon twill', ' ', 'rayon twill', 'katun', ''])
      ).payload

      expect(payload['product_requirement']).to eq(
        [{ 'product_requirement' => 'rayon twill' }, { 'product_requirement' => 'katun' }]
      )
    end

    # Presence of the key, not of a value, decides emission. An explicit empty selection
    # ([]) must ride the payload as [] so removing the final chip on a linked Lead clears
    # the ERP Table MultiSelect child rows on update (an omitted field would let ERP keep
    # the old rows while the sidebar looks empty).
    it 'emits product_requirement: [] when the selection is explicitly empty' do
      payload = described_class.new(valid_fields.merge('product_requirement' => [])).payload

      expect(payload).to have_key('product_requirement')
      expect(payload['product_requirement']).to eq([])
    end

    # A legacy scalar draft whose value was blanked still carries the key, so it too emits
    # [] and clears ERP rather than being silently omitted.
    it 'emits product_requirement: [] for an explicit blank legacy value' do
      payload = described_class.new(valid_fields.merge('product_requirement' => '')).payload

      expect(payload).to have_key('product_requirement')
      expect(payload['product_requirement']).to eq([])
    end

    # Only a truly absent key (a legacy/server-created draft that never had the field) is
    # omitted, so an unrelated field update never unexpectedly wipes existing ERP data.
    it 'omits product_requirement entirely when the key is absent' do
      absent = valid_fields.except('product_requirement')
      payload = described_class.new(absent).payload

      expect(payload).not_to have_key('product_requirement')
    end

    # A manipulated child-row hash must not be able to inject extra DocType fields:
    # only the product_requirement name (and only when it is a String) is ever read.
    it 'cannot inject extra child-row fields from a manipulated hash/object input' do
      manipulated = [
        { 'product_requirement' => 'rayon twill', 'idx' => 5, 'parentfield' => 'evil' },
        { 'product_requirement' => { 'nested' => 'x' } },
        { 'evil' => 'no name' },
        42
      ]
      payload = described_class.new(valid_fields.merge('product_requirement' => manipulated)).payload

      expect(payload['product_requirement']).to eq([{ 'product_requirement' => 'rayon twill' }])
    end

    # product_name/product_price belong ONLY to the Product Requirements create
    # path; the browser must never be able to inject them into the Lead payload.
    it 'never emits product_name/product_price even when the draft carries them' do
      payload = described_class.new(
        valid_fields.merge('product_name' => 'HACK', 'product_price' => 999_999)
      ).payload

      expect(payload).not_to have_key('product_name')
      expect(payload).not_to have_key('product_price')
    end
  end

  # The refresh path (RefreshService) converts ERP Table MultiSelect child rows back
  # into the draft's ordered array of names via this shared normalizer.
  describe '.requirement_names' do
    it 'converts remote child rows into an ordered array of unique names' do
      rows = [
        { 'product_requirement' => 'rayon twill biru muda', 'idx' => 1 },
        { 'product_requirement' => 'rayon twill', 'idx' => 2 },
        { 'product_requirement' => 'rayon twill', 'idx' => 3 }
      ]

      expect(described_class.requirement_names(rows)).to eq(['rayon twill biru muda', 'rayon twill'])
    end

    it 'normalizes a legacy scalar string and blank/nil safely' do
      expect(described_class.requirement_names('LPR-0001')).to eq(['LPR-0001'])
      expect(described_class.requirement_names('')).to eq([])
      expect(described_class.requirement_names(nil)).to eq([])
    end
  end
end
