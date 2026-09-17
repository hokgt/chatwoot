# frozen_string_literal: true

require 'rails_helper'

# WIJAYA deferred_auto_assignment — full request-chain acceptance for the agent-deletion
# DeleteObjectJob race fix. It drives the REAL initiating chain end to end:
#
#   DELETE /api/v1/accounts/:id/agents/:id     (Agents API destroy)
#     -> AccountUser after_destroy :remove_user_from_account
#       -> Agents::DestroyJob   (provenance capture + unassignment + reassignment bridge)
#         -> ProcessInboxJob    (native reassignment of the cleared conversations)
#         -> DeleteObjectJob    (orphaned-User deletion, serialized at the TAIL)
#
# ONLY online status and round-robin selection are stubbed deterministically; provenance capture,
# marker registration, the reassignment bridge and the User deletion all run for real. The original
# bug was a sibling DeleteObjectJob enqueued by the controller that could FK-clear
# conversations.assignee_id before provenance was captured — so the enqueue-ordering assertions here
# are the regression guard, not just the final state.
RSpec.describe 'Agent deletion — serialized orphaned-user removal', type: :request do
  let(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let(:deleted_agent) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:provenance_model) { Wijaya::Batteries::DeferredAutoAssignment::DeletionProvenance }
  let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }
  # Only these jobs are performed, so unrelated conversation-event jobs never turn the drain into a
  # runaway; every step of the deletion chain still runs unmocked.
  let(:deletion_chain) do
    [Agents::DestroyJob, Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob, DeleteObjectJob]
  end

  # Deterministic, Redis-free round-robin: pick the first id from the online∩allowed set the native
  # AgentAssignmentService hands us (proves the candidate SET, not Redis ordering).
  let(:round_robin_picker) do
    instance_double(AutoAssignment::InboxRoundRobinService).tap do |picker|
      %i[add_agent_to_queue remove_agent_from_queue clear_queue reset_queue].each { |m| allow(picker).to receive(m) }
      allow(picker).to receive(:available_agent) do |allowed_agent_ids:|
        ids = Array(allowed_agent_ids)
        ids.empty? ? nil : User.find_by(id: ids.first)
      end
    end
  end

  before do
    account.disable_features!(:assignment_v2) # legacy battery path; assignment_v2 now defaults on
    create(:inbox_member, inbox: inbox, user: deleted_agent)
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
  end

  def online!(*users)
    reachable = users.to_h { |u| [u.id.to_s, 'online'] }
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return(reachable)
  end

  def conversation_assigned_to(agent)
    Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox, assignee: agent)
  end

  def destroy_agent_request
    delete "/api/v1/accounts/#{account.id}/agents/#{deleted_agent.id}", headers: admin.create_new_auth_token, as: :json
  end

  def drain_deletion_chain
    perform_enqueued_jobs(only: deletion_chain) while enqueued_jobs.any? { |job| deletion_chain.include?(job[:job]) }
  end

  it 'reassigns five conversations exactly once to an online member, leaves an unrelated one, and deletes the orphaned user' do
    replacement = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: replacement)
    unrelated_agent = create(:user, account: account, role: :agent)

    conversations = Array.new(5) { conversation_assigned_to(deleted_agent) }
    unrelated = conversation_assigned_to(unrelated_agent)
    online!(replacement) # only the replacement is reachable

    clear_enqueued_jobs # drop setup callbacks; from here we drive only the deletion chain

    # Ordering guard: the request enqueues Agents::DestroyJob and NEVER a sibling DeleteObjectJob.
    destroy_agent_request
    expect(response).to have_http_status(:success)
    enqueued = enqueued_jobs.map { |job| job[:job] }
    expect(enqueued).to include(Agents::DestroyJob)
    expect(enqueued).not_to include(DeleteObjectJob)

    drain_deletion_chain

    expect(provenance_model.where(conversation_id: conversations.map(&:id)).count).to eq(5)
    conversations.each do |conversation|
      expect(conversation.reload.assignee_id).to eq(replacement.id)
      expect(provenance_model.where(conversation_id: conversation.id).count).to eq(1) # captured exactly once
    end
    expect(unrelated.reload.assignee_id).to eq(unrelated_agent.id)          # untouched
    expect(provenance_model.where(conversation_id: unrelated.id)).to be_empty
    expect(marker_model.where(conversation_id: conversations.map(&:id))).to be_empty # cleared once reassigned
    expect(User.exists?(deleted_agent.id)).to be(false)                     # orphaned user eventually deleted
  end

  it 'deletes the orphaned user while five conversations stay unassigned with durable markers/provenance when no agent is eligible' do
    create(:inbox_member, inbox: inbox, user: create(:user, account: account, role: :agent)) # a member, but offline
    conversations = Array.new(5) { conversation_assigned_to(deleted_agent) }
    online! # nobody reachable when the queued pass runs

    clear_enqueued_jobs
    destroy_agent_request
    expect(response).to have_http_status(:success)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(DeleteObjectJob)

    drain_deletion_chain

    expect(provenance_model.where(conversation_id: conversations.map(&:id)).count).to eq(5)
    conversations.each do |conversation|
      expect(conversation.reload.assignee_id).to be_nil                          # still unassigned
      expect(marker_model.exists?(conversation_id: conversation.id)).to be(true) # durable marker retained
    end
    expect(User.exists?(deleted_agent.id)).to be(false)                          # orphaned user still eventually deleted
  end
end
