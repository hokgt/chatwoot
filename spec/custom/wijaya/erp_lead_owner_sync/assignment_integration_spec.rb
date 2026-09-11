# frozen_string_literal: true

require 'rails_helper'

# Post-commit enqueue contract owned by the battery ConversationExtensions concern,
# and proof that Assignment V2's real committed assignee change reaches it without
# altering agent selection. The job itself is stubbed here so these specs assert the
# seam (when it fires and with what), not the ERP push (covered in owner_sync_spec).
RSpec.describe 'ERP Lead owner sync assignment seam', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:agent_b) { create(:user, account: account, role: :agent) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:job) { Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob }

  before do
    allow(job).to receive(:perform_later)
  end

  def link_draft
    Wijaya::ErpLeadDraft.create!(
      account: account, conversation: conversation, fields: {}, erp_lead_id: 'LEAD-0001', sync_status: 'draft'
    )
  end

  describe 'a committed change to a present assignee (nil -> Agent B)' do
    it 'enqueues the owner sync with the committed assignee when a lead is linked' do
      link_draft

      conversation.update!(assignee: agent_b)

      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
    end

    it 'does not enqueue when the conversation has no linked ERP lead' do
      conversation.update!(assignee: agent_b)

      expect(job).not_to have_received(:perform_later)
    end

    it 'does not enqueue when the linked draft has no erp_lead_id yet' do
      Wijaya::ErpLeadDraft.create!(account: account, conversation: conversation, fields: {}, sync_status: 'draft')

      conversation.update!(assignee: agent_b)

      expect(job).not_to have_received(:perform_later)
    end
  end

  describe 'a transition to nil (unassignment / agent removal path)' do
    it 'does not enqueue an owner sync' do
      link_draft
      conversation.update_column(:assignee_id, agent_b.id) # rubocop:disable Rails/SkipsModelValidations

      conversation.update!(assignee_id: nil)

      expect(job).not_to have_received(:perform_later)
    end
  end

  describe 'an update that does not change the assignee' do
    it 'does not enqueue an owner sync' do
      link_draft
      conversation.update_column(:assignee_id, agent_b.id) # rubocop:disable Rails/SkipsModelValidations

      conversation.update!(status: :resolved)

      expect(job).not_to have_received(:perform_later)
    end
  end

  describe 'existing Team behaviour' do
    let(:team) { create(:team, account: account) }
    let(:conversation) do
      create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, team: team)
    end

    it 'leaves the conversation team untouched while syncing the owner' do
      link_draft

      conversation.update!(assignee: agent_b)

      expect(conversation.reload.team_id).to eq(team.id)
      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
    end
  end

  describe "Assignment V2's committed claim" do
    it 'reaches the post-commit seam and still assigns the selected agent' do
      link_draft
      create(:inbox_member, inbox: inbox, user: agent_b)

      claimed = AutoAssignment::AssignmentService.new(inbox: inbox).send(:claim_and_assign, conversation, agent_b)

      expect(claimed).to be(true)
      expect(conversation.reload.assignee_id).to eq(agent_b.id)
      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
    end
  end
end
