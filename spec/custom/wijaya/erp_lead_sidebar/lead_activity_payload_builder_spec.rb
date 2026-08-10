# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::LeadActivityPayloadBuilder do
  let(:submission_id) { '11111111-2222-4333-8444-555555555555' }
  let(:valid_activities) { ['Call', 'WhatsApp', 'Site Visit'] }
  let(:parent) { 'LEAD-0001' }
  let(:person_in_charge) { '' }
  let(:fields) do
    {
      'date' => '2026-08-10',
      'lead_activity' => 'Call',
      'follow_up' => 'No',
      'follow_up_date' => '',
      'follow_up_activity' => '',
      'remark' => 'Spoke with the customer'
    }
  end

  def build(overrides = {})
    described_class.new(
      fields: fields.merge(overrides),
      parent: parent,
      submission_id: submission_id,
      valid_activities: valid_activities,
      person_in_charge: person_in_charge
    )
  end

  describe '#payload' do
    it 'builds the exact frappe.client.insert document with server-owned structural keys' do
      doc = build.payload['doc']

      expect(doc['doctype']).to eq('Lead Activity')
      expect(doc['parenttype']).to eq('Lead')
      expect(doc['parentfield']).to eq('custom_lead_activity')
      expect(doc['parent']).to eq('LEAD-0001')
      expect(doc['date']).to eq('2026-08-10')
      expect(doc['lead_activity']).to eq('Call')
      expect(doc['follow_up']).to eq('No')
    end

    it 'prefixes the remark with the submission marker and one space' do
      doc = build.payload['doc']

      expect(doc['remark']).to eq("[chatwoot:activity:#{submission_id}] Spoke with the customer")
    end

    it 'emits the marker alone (no trailing space) when the remark is blank' do
      doc = build('remark' => '').payload['doc']

      expect(doc['remark']).to eq("[chatwoot:activity:#{submission_id}]")
    end

    it 'forces both follow-up fields empty when follow_up is No' do
      doc = build(
        'follow_up' => 'No',
        'follow_up_date' => '2026-09-01',
        'follow_up_activity' => 'Call'
      ).payload['doc']

      expect(doc['follow_up_date']).to eq('')
      expect(doc['follow_up_activity']).to eq('')
    end

    it 'keeps follow-up fields when follow_up is Yes' do
      doc = build(
        'follow_up' => 'Yes',
        'follow_up_date' => '2026-09-01',
        'follow_up_activity' => 'WhatsApp'
      ).payload['doc']

      expect(doc['follow_up_date']).to eq('2026-09-01')
      expect(doc['follow_up_activity']).to eq('WhatsApp')
    end
  end

  describe '#validate!' do
    def expect_invalid(overrides, message)
      expect { build(overrides).payload }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /#{message}/)
    end

    it 'rejects an invalid submission id' do
      builder = described_class.new(
        fields: fields, parent: parent, submission_id: 'not-a-uuid',
        valid_activities: valid_activities, person_in_charge: person_in_charge
      )
      expect { builder.payload }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /submission_id/)
    end

    it 'requires a linked ERP Lead parent' do
      builder = described_class.new(
        fields: fields, parent: '', submission_id: submission_id,
        valid_activities: valid_activities, person_in_charge: person_in_charge
      )
      expect { builder.payload }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError, /linked ERP Lead/)
    end

    it 'requires a date' do
      expect_invalid({ 'date' => '' }, 'date is required')
    end

    it 'rejects a malformed date' do
      expect_invalid({ 'date' => '2026-13-40' }, 'date must be a valid')
    end

    it 'rejects a non-ISO date shape' do
      expect_invalid({ 'date' => '10/08/2026' }, 'date must be a valid')
    end

    it 'requires a lead_activity' do
      expect_invalid({ 'lead_activity' => '' }, 'lead_activity is required')
    end

    it 'rejects a lead_activity outside the runtime master list' do
      expect_invalid({ 'lead_activity' => 'Unknown' }, 'not a known Lead Activity')
    end

    it 'rejects a follow_up other than No/Yes' do
      expect_invalid({ 'follow_up' => 'Maybe' }, 'follow_up must be No or Yes')
    end

    it 'rejects a malformed follow_up_date when follow_up is Yes' do
      expect_invalid(
        { 'follow_up' => 'Yes', 'follow_up_date' => 'soon' },
        'follow_up_date must be a valid'
      )
    end

    it 'rejects a follow_up_activity outside the master list when follow_up is Yes' do
      expect_invalid(
        { 'follow_up' => 'Yes', 'follow_up_activity' => 'Unknown' },
        'follow_up_activity is not a known Lead Activity'
      )
    end
  end
end
