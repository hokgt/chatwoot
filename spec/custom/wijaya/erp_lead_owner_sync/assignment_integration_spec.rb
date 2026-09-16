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

  # Create an already-linked draft WITHOUT firing the create-time link seam (update_column
  # skips callbacks), so each example isolates the assignee-change seam under test.
  def linked_draft_with(fields)
    draft = Wijaya::ErpLeadDraft.create!(
      account: account, conversation: conversation, sync_status: 'synced', fields: fields
    )
    draft.update_column(:erp_lead_id, 'LEAD-0001') # rubocop:disable Rails/SkipsModelValidations
    draft
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

  describe 'a committed assignee change while a sticky manual override is active' do
    # A newly committed assignment is authoritative: it supersedes the prior manual owner.
    it 'enqueues the owner sync for the new assignee (the assignment supersedes the manual owner)' do
      linked_draft_with('lead_owner' => 'manual-pick@example.com', 'lead_owner_override' => true)

      conversation.update!(assignee: agent_b)

      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
    end

    it 'clears the override and records the new assignee as the intended pending owner' do
      draft = linked_draft_with('lead_owner' => 'manual-pick@example.com', 'lead_owner_override' => true)

      conversation.update!(assignee: agent_b)

      draft.reload
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
      expect(draft.fields).not_to have_key('lead_owner_override')
      expect(draft.fields['lead_owner_sync_pending']).to be(true)
    end

    it 'leaves unrelated draft fields untouched' do
      draft = linked_draft_with(
        'lead_owner' => 'manual-pick@example.com', 'lead_owner_override' => true, 'first_name' => 'Budi'
      )

      conversation.update!(assignee: agent_b)

      expect(draft.reload.fields['first_name']).to eq('Budi')
    end
  end

  describe 'a manual owner selected AFTER an assignment (a non-assignee update must not disturb it)' do
    it 'keeps the manual override and does not enqueue on an update that is not an assignee change' do
      draft = linked_draft_with('lead_owner' => 'manual-later@example.com', 'lead_owner_override' => true)
      conversation.update_column(:assignee_id, agent_b.id) # rubocop:disable Rails/SkipsModelValidations

      conversation.update!(status: :resolved)

      draft.reload
      expect(draft.fields['lead_owner']).to eq('manual-later@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
      expect(job).not_to have_received(:perform_later)
    end
  end

  describe 'a transition to nil (temporary unassignment / agent removal path)' do
    it 'does not enqueue an owner sync and leaves the owner + override untouched' do
      draft = linked_draft_with('lead_owner' => 'manual-pick@example.com', 'lead_owner_override' => true)
      conversation.update_column(:assignee_id, agent_b.id) # rubocop:disable Rails/SkipsModelValidations

      conversation.update!(assignee_id: nil)

      expect(job).not_to have_received(:perform_later)
      draft.reload
      expect(draft.fields['lead_owner']).to eq('manual-pick@example.com')
      expect(draft.fields['lead_owner_override']).to be(true)
    end
  end

  describe 'a final replacement assignment (deletion lifecycle) to a present agent' do
    it 'follows the same assignment-authoritative path (enqueues + clears override)' do
      draft = linked_draft_with('lead_owner' => 'manual-pick@example.com', 'lead_owner_override' => true)
      # The temporary unassignment already committed (assignee cleared); the deferred engine
      # then commits the replacement assignment to a present agent, which reaches this seam.
      conversation.update_column(:assignee_id, nil) # rubocop:disable Rails/SkipsModelValidations

      conversation.update!(assignee: agent_b)

      expect(job).to have_received(:perform_later).with(conversation.id, agent_b.id)
      draft.reload
      expect(draft.fields['lead_owner']).to eq(agent_b.email)
      expect(draft.fields).not_to have_key('lead_owner_override')
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
