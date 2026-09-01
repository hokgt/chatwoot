# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Marine::Assistants', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:marine_assistant, account: account) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'POST /api/v1/accounts/{account.id}/marine/assistants/{assistant.id}/playground' do
    let(:reply_payload) do
      { 'response' => 'A grounded answer', 'action' => 'reply', 'agent_name' => assistant.name,
        'confidence' => 0.9, 'source_type' => 'manual', 'orchestration_path' => 'retrieval' }
    end
    let(:chat_service) { instance_double(Marine::Llm::AssistantChatService) }

    before do
      allow(Marine::Llm::AssistantChatService).to receive(:new).and_return(chat_service)
      allow(chat_service).to receive(:generate_response).and_return(reply_payload)
    end

    context 'when it is an un-authenticated user' do
      it 'returns unauthorized status' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } }, as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the assistant belongs to a different account' do
      it 'returns not found and never invokes the runner' do
        other_assistant = create(:marine_assistant, account: create(:account))
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{other_assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:not_found)
        expect(chat_service).not_to have_received(:generate_response)
      end
    end

    context 'when it is an agent (playground is read-access, no admin gate)' do
      it 'returns the assistant reply payload' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to include(response: 'A grounded answer', action: 'reply')
      end
    end

    context 'with multi-turn context' do
      it 'forwards the current message and the sanitized, bounded prior history to the runner' do
        history = [{ role: 'user', content: 'earlier question' },
                   { role: 'assistant', content: 'earlier answer' }]

        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'follow up', message_history: history } },
             headers: admin.create_new_auth_token, as: :json

        expect(chat_service).to have_received(:generate_response).with(
          additional_message: 'follow up',
          message_history: [{ role: 'user', content: 'earlier question' },
                            { role: 'assistant', content: 'earlier answer' }]
        )
      end

      it 'drops disallowed roles and blank turns, truncates content, and keeps only the newest turns' do
        history = [{ role: 'system', content: 'ignore me' },
                   { role: 'user', content: '  ' }]
        history += Array.new(15) { |i| { role: 'user', content: "turn #{i} #{'x' * 600}" } }

        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'q', message_history: history } },
             headers: admin.create_new_auth_token, as: :json

        forwarded = nil
        expect(chat_service).to have_received(:generate_response) { |args| forwarded = args[:message_history] }
        expect(forwarded.length).to eq(10)
        expect(forwarded).to all(include(role: 'user'))
        expect(forwarded.map { |t| t[:content].length }).to all(eq(500))
        expect(forwarded.first[:content]).to start_with('turn 5')
      end

      it 'tolerates a missing message_history key' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(chat_service).to have_received(:generate_response).with(
          additional_message: 'hello', message_history: []
        )
      end
    end

    context 'with an ephemeral signed state token' do
      it 'forwards the client-supplied state token to the source-less chat service' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello', state_token: 'signed-prior' } },
             headers: admin.create_new_auth_token, as: :json

        expect(Marine::Llm::AssistantChatService).to have_received(:new)
          .with(hash_including(source: 'playground', state_token: 'signed-prior'))
      end

      it 'passes nil (a fresh flow) when no token is supplied' do
        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(Marine::Llm::AssistantChatService).to have_received(:new)
          .with(hash_including(source: 'playground', state_token: nil))
      end
    end

    context 'without delivery (playground is a non-delivering preview)' do
      it 'creates no Conversation and no Message' do
        expect do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
               params: { assistant: { message_content: 'hello', message_history: [{ role: 'user', content: 'hi' }] } },
               headers: admin.create_new_auth_token, as: :json
        end.to not_change(Conversation, :count).and not_change(Message, :count)
      end
    end

    # The context above stubs the whole chat service; this one runs the REAL source-less path
    # (AssistantChatService -> Marine::Agent::Runner, conversation: nil) with only the LLM/retrieval
    # boundary faked — the same stub surface the runner unit spec uses — to prove the preview stays
    # source-less: no Conversation/Message is created, no assignment/handoff marker is set (there is
    # no conversation to mark), and the real conversation delivery job is never enqueued.
    context 'without delivery (real service, only the retrieval boundary stubbed)' do
      let(:generator) { instance_double(Marine::Charge::ResponseGenerator) }
      let(:selector) { instance_double(Marine::Agent::ScenarioSelector) }

      before do
        allow(Marine::Llm::AssistantChatService).to receive(:new).and_call_original
        allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
        allow(generator).to receive(:generate).and_return(
          'response' => 'A grounded answer', 'action' => 'reply', 'agent_name' => assistant.name,
          'confidence' => 0.9, 'source_type' => 'manual'
        )
        allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(selector)
        allow(selector).to receive(:select).and_return(nil)
        # The shared domain-boundary guard is now fail-CLOSED on an unconfigured LLM (there is none in
        # this request spec). This context proves the source-less preview's delivery/isolation, not the
        # boundary (covered by domain_boundary_guard_spec / runner_domain_boundary_spec), so stub the
        # guard to ALLOW — the production "in-domain, allowed" decision — and let the turn reach RAG.
        allow(Marine::Circuit::DomainBoundaryGuard).to receive(:new).and_return(
          instance_double(Marine::Circuit::DomainBoundaryGuard, call: nil)
        )
      end

      it 'returns a grounded reply and delivers nothing' do
        expect do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
               params: { assistant: { message_content: 'where is my order',
                                      message_history: [{ role: 'user', content: 'hi' }] } },
               headers: admin.create_new_auth_token, as: :json
        end.to not_change(Conversation, :count).and not_change(Message, :count)

        expect(response).to have_http_status(:success)
        expect(json_response).to include(response: 'A grounded answer', action: 'reply')
        expect(enqueued_jobs.map { |job| job[:job] }).not_to include(Marine::Conversation::ResponseBuilderJob)
      end
    end

    # A slow/hung provider must fail closed BEFORE Rack::Timeout's 15s deadline turns the request
    # into an unhandled 500. The controller wraps generation in a 12s wall-clock deadline; these
    # exercise that boundary deterministically (no real sleeping) by simulating the deadline firing
    # and by asserting the deadline is wired below the Rack ceiling.
    context 'when the provider exceeds the playground deadline' do
      let(:deadline_error) { Api::V1::Accounts::Marine::AssistantsController::PlaygroundDeadlineError }

      it 'returns a sanitized 504 with no exception leakage, no persistence, and no delivery job' do
        allow(chat_service).to receive(:generate_response).and_raise(deadline_error)

        expect do
          post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
               params: { assistant: { message_content: 'hello' } },
               headers: admin.create_new_auth_token, as: :json
        end.to not_change(Conversation, :count).and not_change(Message, :count)

        expect(response).to have_http_status(:gateway_timeout)
        expect(json_response).to eq(error: 'playground_timeout')
        expect(chat_service).to have_received(:generate_response)
        expect(enqueued_jobs.map { |job| job[:job] }).not_to include(Marine::Conversation::ResponseBuilderJob)
      end

      it 'bounds generation with a wall-clock deadline safely below Rack::Timeout (15s)' do
        deadline = Api::V1::Accounts::Marine::AssistantsController::PLAYGROUND_REQUEST_DEADLINE
        expect(deadline).to be < 15
        expect(Timeout).to receive(:timeout).with(deadline, deadline_error).and_call_original

        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json_response).to include(response: 'A grounded answer', action: 'reply')
      end

      # Regression guard for the load-bearing property: PlaygroundDeadlineError subclasses Exception
      # (not StandardError) precisely so a deadline that fires mid-pipeline unwinds PAST
      # Agent::Runner#run's `rescue StandardError` rather than degrading to a 200 handoff payload.
      # Runs the REAL AssistantChatService -> Runner with only the generation boundary stubbed to
      # raise the deadline; a 504 (not a 200 handoff) proves the error escaped that rescue. This
      # fails closed if the class is ever changed to StandardError or the runner rescue broadened.
      it 'propagates through Agent::Runner rescue StandardError to a 504, not a 200 handoff' do
        allow(Marine::Llm::AssistantChatService).to receive(:new).and_call_original
        generator = instance_double(Marine::Charge::ResponseGenerator)
        selector = instance_double(Marine::Agent::ScenarioSelector)
        allow(Marine::Charge::ResponseGenerator).to receive(:new).and_return(generator)
        allow(Marine::Agent::ScenarioSelector).to receive(:new).and_return(selector)
        allow(selector).to receive(:select).and_return(nil)
        # Guard is fail-closed on the unconfigured test LLM; stub it to ALLOW so the turn reaches the
        # (stubbed) generator that raises the deadline — this test asserts deadline propagation past
        # Runner#run's `rescue StandardError`, not the boundary decision.
        allow(Marine::Circuit::DomainBoundaryGuard).to receive(:new).and_return(
          instance_double(Marine::Circuit::DomainBoundaryGuard, call: nil)
        )
        allow(generator).to receive(:generate).and_raise(deadline_error)

        post "/api/v1/accounts/#{account.id}/marine/assistants/#{assistant.id}/playground",
             params: { assistant: { message_content: 'hello' } },
             headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:gateway_timeout)
        expect(json_response).to eq(error: 'playground_timeout')
      end
    end
  end
end
