# frozen_string_literal: true

FactoryBot.define do
  factory :channel_wecom, class: 'Channel::Wecom' do
    account
    corp_id { "ww#{SecureRandom.hex(8)}" }
    token { SecureRandom.hex(8) }
    # A WeCom EncodingAESKey is a fixed 43-char Base64 string (decodes to 32 bytes).
    encoding_aes_key { Base64.strict_encode64(SecureRandom.random_bytes(32))[0, 43] }
    secret { SecureRandom.hex(16) }
    open_kfid { "wk#{SecureRandom.hex(8)}" }

    # Mirrors the staged setup: a freshly created inbox has only Corp ID + Token +
    # EncodingAESKey; Secret and Open KF ID are revealed/discovered afterwards.
    trait :unconfigured do
      secret { nil }
      open_kfid { nil }
    end

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
