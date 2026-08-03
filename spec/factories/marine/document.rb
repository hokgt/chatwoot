FactoryBot.define do
  factory :marine_document, class: 'Marine::Document' do
    assistant { create(:marine_assistant) }
    name { 'Marine Website Doc' }
    source_kind { 'website' }
    sequence(:external_link) { |n| "https://example.com/page-#{n}" }

    trait :website do
      source_kind { 'website' }
    end

    trait :product_catalog do
      source_kind { 'product_catalog' }
      external_link { nil }
      content { nil }
      product_family_code { 'FAM-001' }
      primary_catalog { true }
      name { 'Marine Product Catalog' }

      after(:build) do |document|
        document.source_file.attach(
          io: StringIO.new('%PDF-1.4 product catalog fixture'),
          filename: 'catalog.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    trait :sop_document do
      source_kind { 'sop_document' }
      external_link { nil }
      name { 'Marine SOP Document' }

      after(:build) do |document|
        document.source_file.attach(
          io: StringIO.new('%PDF-1.4 sop fixture'),
          filename: 'sop.pdf',
          content_type: 'application/pdf'
        )
      end
    end
  end
end
