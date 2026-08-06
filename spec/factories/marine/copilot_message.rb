FactoryBot.define do
  factory :marine_copilot_message, class: 'Marine::CopilotMessage' do
    message_type { :user }
    message { { content: 'Hello Marine' } }
    association :copilot_thread, factory: :marine_copilot_thread
  end
end
