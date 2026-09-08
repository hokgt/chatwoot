# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::CustomTool, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:endpoint_url) }
    it { is_expected.to define_enum_for(:http_method).with_values('GET' => 'GET', 'POST' => 'POST').backed_by_column_of_type(:string) }

    it {
      expect(subject).to define_enum_for(:auth_type).with_values('none' => 'none', 'bearer' => 'bearer', 'basic' => 'basic',
                                                                 'api_key' => 'api_key').backed_by_column_of_type(:string).with_prefix(:auth)
    }

    describe 'slug uniqueness' do
      let(:account) { create(:account) }

      it 'validates uniqueness of slug scoped to account' do
        create(:marine_custom_tool, account: account, slug: 'custom_test_tool')
        duplicate = build(:marine_custom_tool, account: account, slug: 'custom_test_tool')

        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:slug]).to include('has already been taken')
      end

      it 'allows same slug across different accounts' do
        account2 = create(:account)
        create(:marine_custom_tool, account: account, slug: 'custom_test_tool')
        different_account_tool = build(:marine_custom_tool, account: account2, slug: 'custom_test_tool')

        expect(different_account_tool).to be_valid
      end
    end

    describe 'param_schema validation' do
      let(:account) { create(:account) }

      it 'is valid with proper param_schema' do
        tool = build(:marine_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID', 'required' => true }
                     ])

        expect(tool).to be_valid
      end

      it 'is valid with empty param_schema' do
        tool = build(:marine_custom_tool, account: account, param_schema: [])

        expect(tool).to be_valid
      end

      it 'is invalid when param_schema is missing name' do
        tool = build(:marine_custom_tool, account: account, param_schema: [
                       { 'type' => 'string', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'is invalid when param_schema is missing type' do
        tool = build(:marine_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'description' => 'Order ID' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'is invalid when param_schema is missing description' do
        tool = build(:marine_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'is invalid with additional properties in param_schema' do
        tool = build(:marine_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID', 'extra_field' => 'value' }
                     ])

        expect(tool).not_to be_valid
      end

      it 'is valid when required field is omitted (defaults to optional param)' do
        tool = build(:marine_custom_tool, account: account, param_schema: [
                       { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID' }
                     ])

        expect(tool).to be_valid
      end
    end
  end

  describe 'scopes' do
    let(:account) { create(:account) }

    describe '.enabled' do
      it 'returns only enabled custom tools' do
        enabled_tool = create(:marine_custom_tool, account: account, enabled: true)
        disabled_tool = create(:marine_custom_tool, account: account, enabled: false)

        enabled_ids = described_class.enabled.pluck(:id)
        expect(enabled_ids).to include(enabled_tool.id)
        expect(enabled_ids).not_to include(disabled_tool.id)
      end
    end
  end

  describe 'per-account limit' do
    let(:account) { create(:account) }

    it 'raises when the account already has the maximum number of tools' do
      stub_const('Marine::CustomTool::MAX_PER_ACCOUNT', 2)
      create(:marine_custom_tool, account: account)
      create(:marine_custom_tool, account: account)

      expect { create(:marine_custom_tool, account: account) }.to raise_error(Marine::CustomTool::LimitExceededError)
    end
  end

  describe 'slug generation' do
    let(:account) { create(:account) }

    it 'generates slug from title on creation' do
      tool = create(:marine_custom_tool, account: account, title: 'Fetch Order Status')

      expect(tool.slug).to eq('custom_fetch_order_status')
    end

    it 'adds custom_ prefix to generated slug' do
      tool = create(:marine_custom_tool, account: account, title: 'My Tool')

      expect(tool.slug).to start_with('custom_')
    end

    it 'does not override manually set slug' do
      tool = create(:marine_custom_tool, account: account, title: 'Test Tool', slug: 'custom_manual_slug')

      expect(tool.slug).to eq('custom_manual_slug')
    end

    it 'handles slug collisions by appending random suffix' do
      create(:marine_custom_tool, account: account, title: 'Test Tool', slug: 'custom_test_tool')
      tool2 = create(:marine_custom_tool, account: account, title: 'Test Tool')

      expect(tool2.slug).to match(/^custom_test_tool_[a-z0-9]{6}$/)
    end

    it 'does not generate slug when title is blank' do
      tool = build(:marine_custom_tool, account: account, title: nil)

      expect(tool).not_to be_valid
      expect(tool.errors[:title]).to include("can't be blank")
    end

    it 'parameterizes title correctly' do
      tool = create(:marine_custom_tool, account: account, title: 'Fetch Order Status & Details!')

      expect(tool.slug).to eq('custom_fetch_order_status_details')
    end
  end

  describe 'factory' do
    it 'creates a valid custom tool with default attributes' do
      tool = create(:marine_custom_tool)

      expect(tool).to be_valid
      expect(tool.title).to be_present
      expect(tool.slug).to be_present
      expect(tool.endpoint_url).to be_present
      expect(tool.http_method).to eq('GET')
      expect(tool.auth_type).to eq('none')
      expect(tool.enabled).to be true
    end

    it 'creates valid tool with bearer auth trait' do
      tool = create(:marine_custom_tool, :with_bearer_auth)

      expect(tool.auth_type).to eq('bearer')
      expect(tool.auth_config['token']).to eq('test_bearer_token_123')
    end
  end

  # Custom-tool execution has been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP. The Toolable concern is retained for
  # Zeitwerk autoloading but every request/auth/metadata/response builder is now
  # a no-op so nothing can construct or execute an outbound tool request.
  describe 'Toolable concern (disabled, no-op builders)' do
    let(:account) { create(:account) }

    it '#tool returns nil' do
      tool = create(:marine_custom_tool, :with_params, account: account)

      expect(tool.tool(nil)).to be_nil
    end

    it '#build_request_url returns nil' do
      tool = create(:marine_custom_tool, account: account, endpoint_url: 'https://api.example.com/orders/{{ order_id }}')

      expect(tool.build_request_url({ order_id: '12345' })).to be_nil
    end

    it '#build_request_body returns nil' do
      tool = create(:marine_custom_tool, :with_templates, account: account)

      expect(tool.build_request_body({ order_id: '12345' })).to be_nil
    end

    it '#build_auth_headers returns an empty hash' do
      tool = create(:marine_custom_tool, :with_bearer_auth, account: account)

      expect(tool.build_auth_headers).to eq({})
    end

    it '#build_basic_auth_credentials returns nil' do
      tool = create(:marine_custom_tool, :with_basic_auth, account: account)

      expect(tool.build_basic_auth_credentials).to be_nil
    end

    it '#format_response returns nil' do
      tool = create(:marine_custom_tool, :with_templates, account: account)

      expect(tool.format_response('{"status": "shipped"}')).to be_nil
    end

    it '#build_metadata_headers returns an empty hash' do
      tool = create(:marine_custom_tool, account: account, slug: 'custom_test_tool')

      expect(tool.build_metadata_headers({ account_id: account.id })).to eq({})
    end
  end

  describe '#to_tool_metadata' do
    let(:account) { create(:account) }

    it 'returns tool metadata hash with custom flag' do
      tool = create(:marine_custom_tool, account: account,
                                         slug: 'custom_test-tool',
                                         title: 'Test Tool',
                                         description: 'A test tool')

      metadata = tool.to_tool_metadata
      expect(metadata).to eq({
                               id: 'custom_test-tool',
                               title: 'Test Tool',
                               description: 'A test tool',
                               custom: true
                             })
    end
  end
end
