# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/routing_service')
require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/routing_rule')

# End-to-end acceptance matrix for the Meta Ads online team-assignment phase.
#
# It exercises the REAL flow the channel builders run: build native
# conversation_params -> Wijaya RoutingService injects only team_id -> native
# Conversation.create! -> Chatwoot's native assignment engine
# (AssignmentHandler#ensure_assignee_is_from_team + AutoAssignmentHandler +
# AutoAssignment::AgentAssignmentService) intersects Inbox members ∩ Team members ∩
# capacity ∩ ONLINE and round-robins, leaving assignee_id nil when nobody is eligible.
#
# No new production code backs these examples: the battery already injects team_id and
# the native engine already does the eligibility/round-robin/nil-fallback work. Every
# example is therefore an acceptance assertion against the UNCHANGED native engine.
#
# Redis safety: exactly three boundaries reach live Redis, and all three are stubbed, so
# no example reads, writes, or flushes any real key:
#   - OnlineStatusTracker.get_available_users -> the presence map (no presence-key reads);
#   - the InboxRoundRobinService selector -> round-robin queue reads/writes/maintenance;
#   - AutoAssignment::AssignmentJob.enqueue_for_inbox -> the Assignment V2 in-flight
#     coalescing key (::Redis::Alfred.set nx) AND the enqueued bulk V2 AssignmentJob.
# Everything else runs unstubbed as native production code: AssignmentHandler (Path A,
# before_save), AutoAssignmentHandler (Path B, after_save), and the AgentAssignmentService
# candidate intersection. The stubbed selector rotates deterministically over exactly the
# online∩allowed set the native chain computes, so it proves the candidate set (not Redis
# ordering); native round-robin ordering itself is covered by spec/services/auto_assignment.
RSpec.describe 'Meta Ads online team assignment (acceptance)', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:team) { create(:team, account: account, allow_auto_assign: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:source_id) { 'AD_ONLINE_1' }

  # Active Ad ID -> Team mapping (created inline; the battery has no factory).
  let!(:rule) do
    Wijaya::MetaAdsTeamRoutingRule.create!(account: account, team: team, source_id: source_id, status: :active)
  end

  # Presence map { user_id_string => status }; contexts override `online_ids`.
  let(:online_ids) { [] }
  let(:online_presence) { online_ids.index_with { 'online' } }

  # Deterministic, Redis-free round-robin: pick from the online∩allowed set the native
  # AgentAssignmentService hands us, rotating across successive conversations.
  let(:round_robin_picker) do
    instance_double(AutoAssignment::InboxRoundRobinService).tap do |picker|
      # Swallow the InboxMember/Inbox queue-maintenance callbacks (add/remove/clear/reset)
      # as no-ops so setup never writes to a live Redis round-robin key.
      allow(picker).to receive(:add_agent_to_queue)
      allow(picker).to receive(:remove_agent_from_queue)
      allow(picker).to receive(:clear_queue)
      allow(picker).to receive(:reset_queue)
      cursor = { i: 0 }
      allow(picker).to receive(:available_agent) do |allowed_agent_ids:|
        ids = Array(allowed_agent_ids)
        if ids.empty?
          nil
        else
          chosen = ids[cursor[:i] % ids.length]
          cursor[:i] += 1
          User.find_by(id: chosen)
        end
      end
    end
  end

  before do
    allow(AutoAssignment::InboxRoundRobinService).to receive(:new).and_return(round_robin_picker)
    allow(OnlineStatusTracker).to receive(:get_available_users) { online_presence }
    # Under Assignment V2, AutoAssignmentHandler#run_auto_assignment (Path B, after_save)
    # calls AssignmentJob.enqueue_for_inbox, whose implementation writes a per-inbox
    # in-flight key to Redis (::Redis::Alfred.set nx) before enqueuing a bulk V2
    # AssignmentJob. Stub that narrow public boundary so no acceptance example touches live
    # Redis or runs real V2 assignment work. Path A (AssignmentHandler, before_save) still
    # sets the assignee via the unstubbed native selector, so the V2/V3 assertions below
    # hold; native V2 assignment selection itself is covered by
    # spec/services/auto_assignment/assignment_service_spec.rb.
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  # Build an agent and control its Team / Inbox membership independently.
  def make_agent(team_member: true, inbox_member: true)
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user) if inbox_member
    create(:team_member, team: team, user: user) if team_member
    user
  end

  REFERRALS = {
    whatsapp: ->(sid) { { source_id: sid, source_type: 'ad' } },
    messenger: ->(sid) { { ad_id: sid, source: 'ads' } },
    instagram: ->(sid) { { ad_id: sid, source: 'ads' } }
  }.freeze

  # Full acceptance path: native params -> RoutingService (real per-channel referral
  # normalization) -> Conversation.create! -> native assignment engine.
  def create_routed_conversation(channel: :whatsapp, referral: :mapped, params: {})
    referral = REFERRALS.fetch(channel).call(source_id) if referral == :mapped
    # Pass associations as objects so the created conversation carries these exact
    # instances; callbacks (and per-example stubs like capacity) then act on them.
    base = { account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }
    routed = Wijaya::Batteries::MetaAdsTeamRouting::RoutingService.apply!(
      account: account, inbox: inbox, channel: channel, referral: referral,
      conversation_params: base.merge(params)
    )
    Conversation.create!(routed)
  end

  describe 'mapped Ad, one online eligible agent (M1, CH1-CH3)' do
    let!(:agent) { make_agent }
    let(:online_ids) { [agent.id.to_s] }

    REFERRALS.each_key do |channel|
      it "routes to the mapped team and assigns the online agent for #{channel}" do
        conversation = create_routed_conversation(channel: channel)

        expect(conversation.team).to eq(team)
        expect(conversation.assignee).to eq(agent)
      end
    end
  end

  describe 'mapped Ad, several online eligible agents (M2 round-robin)' do
    let!(:agent_a) { make_agent }
    let!(:agent_b) { make_agent }
    let(:online_ids) { [agent_a.id.to_s, agent_b.id.to_s] }

    it 'distributes successive routed conversations across the eligible agents' do
      first = create_routed_conversation
      second = create_routed_conversation

      expect([first.assignee, second.assignee]).to contain_exactly(agent_a, agent_b)
      [first, second].each { |conversation| expect(conversation.team).to eq(team) }
    end
  end

  describe 'mapped Ad, nobody online (M3 fallback)' do
    let!(:agent) { make_agent }
    let(:online_ids) { [] } # eligible member exists but is offline

    it 'keeps the mapped team, leaves assignee nil, and does not leak to another team' do
      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
      # Discoverable in the team's unassigned queue for manual SPV assignment.
      expect(Conversation.where(team: team, assignee_id: nil)).to include(conversation)
    end
  end

  describe 'fail-open routing guards (M4-M8)' do
    # An eligible member exists but is intentionally offline, so native inbox-level
    # auto-assignment (which is orthogonal to Ad->Team routing) does not mask the
    # routing-only assertions: these rows are about NOT routing to a team.
    let!(:agent) { make_agent }
    let(:online_ids) { [] }

    it 'does not route or assign for an unmapped source_id (M4)' do
      conversation = create_routed_conversation(referral: { source_id: 'UNMAPPED_AD', source_type: 'ad' })

      expect(conversation.team).to be_nil
      expect(conversation.assignee).to be_nil
    end

    it 'does not route or assign organic traffic with no referral (M5)' do
      conversation = create_routed_conversation(referral: nil)

      expect(conversation.team).to be_nil
      expect(conversation.assignee).to be_nil
    end

    it 'does not route or assign when source_id is missing/blank (M6)' do
      conversation = create_routed_conversation(referral: { source_type: 'ad' })

      expect(conversation.team).to be_nil
      expect(conversation.assignee).to be_nil
    end

    it 'never overrides a team_id already present in the params (M7)' do
      other_team = create(:team, account: account, allow_auto_assign: true)
      other_agent = create(:user, account: account, role: :agent)
      create(:inbox_member, inbox: inbox, user: other_agent)
      create(:team_member, team: other_team, user: other_agent)

      conversation = create_routed_conversation(params: { team_id: other_team.id })

      # Pre-set team wins; native assignment runs against THAT team, not the mapped one.
      expect(conversation.team).to eq(other_team)
    end

    it 'routes only the newly created conversation and leaves a pre-existing team-less one untouched (M8)' do
      # Model-level routing isolation, NOT a test of the channel builders' reuse guard.
      # This creates the pre-existing conversation directly and never invokes a channel
      # builder, so it does not exercise the `return if @conversation` short-circuit that
      # actually protects reused conversations (that seam lives in the builders, e.g.
      # app/services/whatsapp/incoming_message_base_service.rb, and is out of scope here).
      # It asserts the weaker but real property that RoutingService.apply! +
      # Conversation.create! touch only the conversation being created, leaving an existing
      # team-less conversation exactly as it was.
      existing = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      routed = create_routed_conversation

      expect(routed.team).to eq(team)
      expect(existing.reload.team).to be_nil
      expect(existing.assignee).to be_nil
    end
  end

  describe 'eligibility intersection Inbox ∩ Team ∩ online ∩ capacity (E1-E4)' do
    it 'excludes a Team member who is NOT an Inbox member (E1)' do
      agent = make_agent(team_member: true, inbox_member: false)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
    end

    it 'excludes an Inbox member who is NOT a Team member (E2)' do
      agent = make_agent(team_member: false, inbox_member: true)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
    end

    it 'excludes an eligible member who is OFFLINE (E3)' do
      make_agent # eligible member, but presence map below marks nobody online
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
    end

    it 'excludes an online eligible member who is over capacity (E4)' do
      agent = make_agent
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })
      # Capacity is honored through the native Inbox#member_ids_with_assignment_capacity
      # interface (OSS: members.ids; EE: capacity-filtered). Simulate "over capacity" by
      # having that stable interface drop the agent, without EE-only assumptions. Stubbed on
      # the exact inbox instance the conversation carries (any_instance is unsupported for the
      # EE-prepended override).
      allow(inbox).to receive(:member_ids_with_assignment_capacity).and_return([])

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
    end
  end

  describe 'native Team.allow_auto_assign control (C1-C2)' do
    let!(:agent) { make_agent }
    let(:online_ids) { [agent.id.to_s] }

    it 'assigns an eligible online agent when allow_auto_assign is true (C1)' do
      team.update!(allow_auto_assign: true)

      conversation = create_routed_conversation

      expect(conversation.assignee).to eq(agent)
    end

    it 'keeps the team but assigns nobody when allow_auto_assign is false (C2)' do
      team.update!(allow_auto_assign: false)

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
    end
  end

  describe 'native Inbox auto-assignment control (I1-I2)' do
    let!(:agent) { make_agent }
    let(:online_ids) { [agent.id.to_s] }

    it 'assigns when inbox.enable_auto_assignment is true (I1)' do
      inbox.update!(enable_auto_assignment: true)

      conversation = create_routed_conversation

      expect(conversation.assignee).to eq(agent)
    end

    it 'still assigns via the before_save team handler when the inbox toggle is off but ' \
       'allow_auto_assign is true (I2, native Quirk-1)' do
      # Documented native behavior: AssignmentHandler#ensure_assignee_is_from_team (Path A,
      # before_save) is gated only by team.allow_auto_assign and ignores
      # inbox.enable_auto_assignment. This is stock Chatwoot, asserted as truth here; any
      # "inbox toggle fully suppresses routed auto-assignment" preference is an upstream
      # product decision, not patched here.
      inbox.update!(enable_auto_assignment: false)

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to eq(agent)
    end
  end

  describe 'legacy vs Assignment V2 selection (V1-V3)' do
    let!(:agent) { make_agent }

    it 'assigns via the legacy round-robin when assignment_v2 is off (V1)' do
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })

      conversation = create_routed_conversation

      expect(conversation.assignee).to eq(agent)
    end

    it 'assigns an eligible online team member when assignment_v2 is on (V2, native Quirk-2)' do
      # Under assignment_v2, the create-time before_save handler (Path A) still uses the
      # legacy selector and can assign before the V2 AssignmentJob runs. Asserted as native
      # truth; V2-exclusive selection for routed conversations is an upstream product
      # decision. V2 AssignmentService team/online filtering itself is covered by
      # spec/services/auto_assignment/assignment_service_spec.rb.
      # Stubbed on the exact inbox instance the conversation carries (same pattern as the
      # E4 capacity case), so no any_instance leakage to unrelated Inbox instances.
      allow(inbox).to receive(:auto_assignment_v2_enabled?).and_return(true)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to eq(agent)
    end

    it 'keeps the team and assigns nobody when assignment_v2 is on and none are online (V3)' do
      # Concrete-instance stub (see V2) plus the setup-level enqueue_for_inbox stub keep
      # Path B from writing any live Redis in-flight key when nobody is eligible.
      allow(inbox).to receive(:auto_assignment_v2_enabled?).and_return(true)
      allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})

      conversation = create_routed_conversation

      expect(conversation.team).to eq(team)
      expect(conversation.assignee).to be_nil
    end
  end
end
