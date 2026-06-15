FactoryBot.define do
  factory :custom_role do
    account
    name { Faker::Name.name }
    description { Faker::Lorem.sentence }
    permissions { ['conversation_manage'] }
  end
end
