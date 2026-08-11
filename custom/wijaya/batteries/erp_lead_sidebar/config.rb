# frozen_string_literal: true

# Static, Chatwoot-side configuration for the ERP Lead Sidebar battery.
#
# This module is the single backend source of truth for:
#   * the ERPNext endpoint/auth (resolved per account from the encrypted
#     Wijaya::ErpSetting row, falling back to ENV; never hardcode secrets),
#   * the frozen Lead DocType name,
#   * the allowed `status` Select values, and
#   * the authoritative lists of individual checkbox integer fields for the
#     "Market Customer" and "Jenis Pakaian" groups.
#
# The ERP field contract is frozen: do NOT add fields here that are not part
# of the approved dev-tex mapping. Source/campaign/agent autofill *mappings*
# live on the frontend (see frontend/mappings.js) because they only drive the
# initial autofill of the draft; the backend simply serializes whatever the
# agent confirmed in the draft.
module Wijaya::Batteries::ErpLeadSidebar::Config
  module_function

  # Frozen ERPNext DocType we create.
  DOCTYPE = 'Lead'

  # Select-option source DocTypes. Maps the Chatwoot draft field to the
  # ERPNext DocType whose document `name`s populate that dropdown. This is a
  # strict whitelist: the options endpoint only ever queries these DocTypes.
  OPTION_DOCTYPES = {
    'utm_source' => 'UTM Source',
    'utm_campaign' => 'UTM Campaign',
    'territory' => 'Territory',
    'industry' => 'Industry Type'
  }.freeze

  # Allowed values for the required `status` Select field. Order matches the
  # dev-tex contract. `Lead` is the default.
  STATUS_VALUES = [
    'Lead', 'Qualified', 'Catalogue Request', 'Sample Request', 'Converted', 'Regular Customer', 'Lost Quotation'
  ].freeze

  DEFAULT_STATUS = 'Lead'

  # Market Customer checkbox group -> individual integer fields.
  # NEVER send the aggregate custom_market_customer.
  MARKET_CUSTOMER_FIELDS = %w[
    custom_brand_sendiri
    custom_oem_brand
    custom_oem_non_brand
    custom_online_store
    custom_distribusi_kain
    custom_retail_kain
    custom_tailor
    custom_wedding
    custom_sekolah
    custom_instansi_pemerintahan
  ].freeze

  # Jenis Pakaian checkbox group -> individual integer fields.
  # NEVER send the aggregate custom_jenis_pakaian.
  JENIS_PAKAIAN_FIELDS = %w[
    custom_gamis
    custom_dress
    custom_tshirt
    custom_kemeja
    custom_celana_pria
    custom_celana_wanita
    custom_jaket
    custom_sweater__hoody
    custom_seragam_sekolah
    custom_jas
    custom_gaun_pengantin
    custom_kaus_kaki
    custom_seragam_kantor
    custom_seragam_pemerintahan
    custom_kebaya
    custom_sport
    custom_piyama
    custom_lingeri
    custom_pakaian_anak
    custom_pakaian_bayi
    custom_pakaian_dalam
    custom_batik
    custom_jeans
    custom_hijab
  ].freeze

  # --- ERPNext connection ---------------------------------------------------
  # Resolution for host/key/secret, per account:
  #   * When the account has a saved Wijaya::ErpSetting row, that row is
  #     authoritative: its stored host/key/secret are used as-is and the global
  #     ENV values are NOT consulted (a saved account never silently borrows the
  #     deployment-wide credentials, which could point at a different ERPNext).
  #   * Only when the account has NO saved row do we fall back to the global ENV
  #     values (WIJAYA_ERP_*), preserving the original backward-compatible
  #     behavior for accounts that never configured the sidebar.
  # Passing no account resolves ENV only (the original global behavior; kept so
  # any legacy caller stays valid). A genuine database error is NOT swallowed
  # into a silent ENV fallback — see erp_setting_for.
  def erp_base_url(account = nil)
    resolve(account, :host, 'WIJAYA_ERP_BASE_URL')
  end

  def erp_api_key(account = nil)
    resolve(account, :api_key, 'WIJAYA_ERP_API_KEY')
  end

  def erp_api_secret(account = nil)
    resolve(account, :api_secret, 'WIJAYA_ERP_API_SECRET')
  end

  # True only when every piece needed to reach ERPNext resolves for the account.
  def erp_configured?(account = nil)
    erp_base_url(account).present? && erp_api_key(account).present? && erp_api_secret(account).present?
  end

  # Single resolution point. A saved row is authoritative (its value, even blank,
  # wins and never mixes with ENV); ENV applies only when no row exists.
  def resolve(account, attribute, env_key)
    setting = erp_setting_for(account)
    return setting.public_send(attribute).presence if setting

    ENV[env_key].presence
  end

  # Loads the per-account settings row, or nil when there is no account, the
  # model has not loaded yet, or the backing table does not exist yet (boot /
  # pre-migration). A real query error is deliberately allowed to raise rather
  # than being rescued into a silent ENV fallback.
  def erp_setting_for(account)
    return nil if account.nil?
    return nil unless defined?(::Wijaya::ErpSetting)
    return nil unless ::Wijaya::ErpSetting.table_exists?

    account_id = account.respond_to?(:id) ? account.id : account
    ::Wijaya::ErpSetting.find_by(account_id: account_id)
  end

  def status_allowed?(value)
    STATUS_VALUES.include?(value.to_s)
  end
end
