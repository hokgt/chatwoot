# == Schema Information
#
# Table name: channel_wecom
#
#  id               :bigint           not null, primary key
#  encoding_aes_key :text             not null
#  open_kfid        :string
#  secret           :text
#  sync_cursor      :string
#  token            :text             not null
#  corp_id          :string           not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :integer          not null
#
# Indexes
#
#  index_channel_wecom_on_corp_id    (corp_id)
#  index_channel_wecom_on_open_kfid  (open_kfid) UNIQUE WHERE open_kfid IS NOT NULL
#
class Channel::Wecom < ApplicationRecord
  include Channelable

  self.table_name = 'channel_wecom'

  # EncodingAESKey is a fixed 43-character Base64 string per the WeCom spec.
  ENCODING_AES_KEY_LENGTH = 43

  EDITABLE_ATTRS = [:corp_id, :open_kfid, :secret, :token, :encoding_aes_key].freeze

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  if Chatwoot.encryption_configured?
    encrypts :secret
    encrypts :token
    encrypts :encoding_aes_key
  end

  # Secret and Open KF ID are intentionally optional at creation. In the standalone
  # 微信客服 console (开发配置 → 企业内部接入) the corp-scoped callback is verified using
  # only Token + EncodingAESKey; WeCom reveals the Secret only afterwards, and the
  # Open KF ID is discovered from kf/account/list once the Secret exists.
  validates :corp_id, presence: true
  validates :token, presence: true
  validates :encoding_aes_key, presence: true, length: { is: ENCODING_AES_KEY_LENGTH }
  validates :open_kfid, uniqueness: true, allow_blank: true

  before_validation :normalize_open_kfid
  after_update_commit :discover_open_kfid, if: :secret_just_configured?

  def name
    'WeCom'
  end

  private

  # Collapse a blank Open KF ID to NULL before validation so the partial unique index
  # (open_kfid ... WHERE open_kfid IS NOT NULL) never sees an empty string. Without this
  # a second unconfigured inbox would hit the index on '' and fail to save.
  def normalize_open_kfid
    self.open_kfid = nil if open_kfid.blank?
  end

  # Trigger the one-time Open KF ID discovery only when a Secret was just saved and
  # no Open KF ID has been chosen yet. Delegated to the wecom_channel battery through
  # the fail-open hook dispatcher, so a missing/broken battery never breaks the save.
  def secret_just_configured?
    saved_change_to_secret? && secret.present? && open_kfid.blank?
  end

  def discover_open_kfid
    Wijaya::Batteries::Core::Hooks.dispatch(:wecom_channel, :secret_configured, default: nil, channel: self)
  end
end
