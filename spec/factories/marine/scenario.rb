FactoryBot.define do
  factory :marine_scenario, class: 'Marine::Scenario' do
    sequence(:title) { |n| "Marine Scenario #{n}" }
    description { 'Test Marine scenario description' }
    instruction { 'Test Marine scenario instruction for the assistant to follow' }
    tools { [] }
    enabled { true }
    association :assistant, factory: :marine_assistant
    association :account
  end
end
