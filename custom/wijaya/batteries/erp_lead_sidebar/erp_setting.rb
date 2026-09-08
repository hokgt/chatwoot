# frozen_string_literal: true

# Per-account ERPNext connection settings for the ERP Lead Sidebar battery.
# Stores the ERPNext host plus the API key/secret. Credentials are encrypted at
# rest by Active Record Encryption using a battery-specific key provider derived
# from Chatwoot's stable secret_key_base. This remains isolated from optional
# installation-wide Active Record Encryption keys. One row per account.
#
# Credentials are never exposed by the API: the settings controller returns only
# presence/source metadata, never the decrypted values.
#
# Loaded via the battery loader's to_prepare block (require, not Zeitwerk) since
# it lives under the non-autoloaded custom/ battery path.
class Wijaya::ErpSetting < ApplicationRecord
  self.table_name = 'wijaya_erp_settings'

  belongs_to :account

  ERP_ENCRYPTION_KEY = ActiveSupport::KeyGenerator.new(
    Rails.application.secret_key_base
  ).generate_key('wijaya-erp-settings-v1', 32)
  ERP_KEY_PROVIDER = ActiveRecord::Encryption::KeyProvider.new(
    [ActiveRecord::Encryption::Key.new(ERP_ENCRYPTION_KEY)]
  )
  private_constant :ERP_ENCRYPTION_KEY, :ERP_KEY_PROVIDER

  encrypts :api_key, key_provider: ERP_KEY_PROVIDER, support_unencrypted_data: false
  encrypts :api_secret, key_provider: ERP_KEY_PROVIDER, support_unencrypted_data: false

  validates :account_id, uniqueness: true
  validates :host, presence: true
  validate :validate_host

  before_validation :normalize_host

  private

  def normalize_host
    return if host.blank?

    self.host = ::Wijaya::Batteries::ErpLeadSidebar::HostValidator.normalize(host)
  end

  def validate_host
    return if host.blank?

    error = ::Wijaya::Batteries::ErpLeadSidebar::HostValidator.error_for(host)
    errors.add(:host, error) if error
  end
end
