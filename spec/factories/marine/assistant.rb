FactoryBot.define do
  factory :marine_assistant, class: 'Marine::Assistant' do
    sequence(:name) { |n| "Marine Assistant #{n}" }
    description { 'A Marine AI assistant for testing' }
    association :account
  end
end
