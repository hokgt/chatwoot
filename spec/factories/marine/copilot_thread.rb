FactoryBot.define do
  factory :marine_copilot_thread, class: 'Marine::CopilotThread' do
    sequence(:title) { |n| "Marine copilot thread #{n}" }
    association :account
    association :user
    association :assistant, factory: :marine_assistant
  end
end
