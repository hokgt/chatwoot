# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for the native `defined?(Wijaya::Batteries::Core::Hooks)` guards.
#
# In a booted app the generic initializer (config/initializers/wijaya.rb) loads the core
# hooks module, so every seam dispatches normally. These specs prove the OTHER branch:
# when the battery system never booted (the constant is undefined), each native touch
# point uses/returns its EXACT upstream default and never raises NameError.
#
# The constant is removed per-example with RSpec's `hide_const`, which isolates and
# restores the constant automatically — Rails constants are never globally destabilized.
RSpec.describe 'Wijaya native seams fail open when Core::Hooks is undefined' do
  it 'sanity: the constant is normally defined in the booted test app' do
    expect(defined?(Wijaya::Batteries::Core::Hooks)).to be_truthy
  end

  describe 'DashboardController#app_config (development_version seam)' do
    subject(:controller) { DashboardController.new }

    before do
      allow(VapidService).to receive(:public_key).and_return('vapid-key')
      allow(controller).to receive_messages(allowed_login_methods: ['email'], active_platform_banners: [])
    end

    it 'returns the native config unchanged (no battery enrichment) when the constant is undefined' do
      hide_const('Wijaya::Batteries::Core::Hooks')

      config = controller.send(:app_config)

      expect(config).not_to have_key(:WIJAYA_DEV_VERSION)
      expect(config[:APP_VERSION]).to eq(Chatwoot.config[:version])
    end
  end

  describe 'MessageTemplates::HookExecutionService#trigger_templates (marine_ai claim seam)' do
    subject(:service) { MessageTemplates::HookExecutionService.new(message: instance_double(Message)) }

    before do
      allow(service).to receive_messages(
        should_send_out_of_office_message?: true,
        should_send_greeting?: false,
        conversation: instance_double(Conversation),
        inbox: instance_double(Inbox, enable_email_collect: false)
      )
      # The Enterprise override wraps trigger_templates (super) with a Captain-response
      # step; stub its predicate off so this spec stays focused on the native templates.
      allow(service).to receive(:should_process_captain_response?).and_return(false)
    end

    it 'runs the native templates (Marine never claims) when the constant is undefined' do
      hide_const('Wijaya::Batteries::Core::Hooks')

      out_of_office = instance_double(MessageTemplates::Template::OutOfOffice, perform: nil)
      expect(MessageTemplates::Template::OutOfOffice).to receive(:new).and_return(out_of_office)
      expect(out_of_office).to receive(:perform)

      expect { service.send(:trigger_templates) }.not_to raise_error
    end
  end

  describe 'Messages::Facebook::MessageBuilder#build_conversation (meta_ads_team_routing seam)' do
    subject(:builder) { Messages::Facebook::MessageBuilder.new(response, inbox) }

    let(:account) { instance_double(Account) }
    let(:inbox) { instance_double(Inbox, account_id: 1, id: 2, account: account) }
    let(:contact_inbox) { instance_double(ContactInbox, id: 9, contact_id: 3) }
    let(:response) { instance_double(Integrations::Facebook::MessageParser, recipient_id: 'r', sender_id: 's', attachments: [], referral: nil) }

    before { builder.instance_variable_set(:@contact_inbox, contact_inbox) }

    it 'creates the conversation with the exact native params when the constant is undefined' do
      hide_const('Wijaya::Batteries::Core::Hooks')

      expect(Conversation).to receive(:create!).with({ account_id: 1, inbox_id: 2, contact_id: 3, contact_inbox_id: 9 })

      builder.send(:build_conversation)
    end
  end

  describe 'Messages::Instagram::BaseMessageBuilder#build_conversation (meta_ads_team_routing seam)' do
    subject(:builder) { Messages::Instagram::BaseMessageBuilder.new({ referral: nil }, inbox) }

    let(:inbox) { instance_double(Inbox, account_id: 1, id: 2, account: instance_double(Account)) }
    let(:contact_inbox) { instance_double(ContactInbox, id: 9) }
    let(:contact) { instance_double(Contact, id: 3) }

    before do
      builder.instance_variable_set(:@contact_inbox, contact_inbox)
      builder.instance_variable_set(:@contact, contact)
    end

    it 'creates the conversation with the exact native params when the constant is undefined' do
      hide_const('Wijaya::Batteries::Core::Hooks')

      expect(Conversation).to receive(:create!).with(
        { account_id: 1, inbox_id: 2, contact_id: 3, contact_inbox_id: 9, additional_attributes: {} }
      )

      builder.send(:build_conversation)
    end
  end

  describe 'Whatsapp::IncomingMessageBaseService#set_conversation (meta_ads_team_routing seam)' do
    subject(:service) { Whatsapp::IncomingMessageBaseService.new(inbox: inbox, params: {}) }

    let(:conversations) { instance_double(ActiveRecord::Relation, last: nil) }
    let(:contact_inbox) { instance_double(ContactInbox, id: 9, conversations: conversations) }
    let(:contact) { instance_double(Contact, id: 3) }
    let(:inbox) { instance_double(Inbox, account_id: 1, id: 2, lock_to_single_conversation: true) }

    before do
      service.instance_variable_set(:@contact_inbox, contact_inbox)
      service.instance_variable_set(:@contact, contact)
    end

    it 'creates the conversation with the exact native params when the constant is undefined' do
      hide_const('Wijaya::Batteries::Core::Hooks')

      expect(Conversation).to receive(:create!).with({ account_id: 1, inbox_id: 2, contact_id: 3, contact_inbox_id: 9 })

      service.send(:set_conversation)
    end
  end

  describe '_inbox.json.jbuilder (marine_ai inbox_marine_assistant_id seam)', type: :request do
    let(:inbox) { create(:inbox) }

    def render_inbox
      ApplicationController.render(partial: 'api/v1/models/inbox', formats: [:json], locals: { resource: inbox })
    end

    it 'emits the marine_assistant_id field (fail-open null) when the constant is defined' do
      json = JSON.parse(render_inbox)

      expect(json).to have_key('marine_assistant_id')
    end

    it 'omits the custom field entirely (native JSON) when the constant is undefined' do
      hide_const('Wijaya::Batteries::Core::Hooks')

      json = JSON.parse(render_inbox)

      expect(json).not_to have_key('marine_assistant_id')
      expect(json['id']).to eq(inbox.id)
    end
  end
end
