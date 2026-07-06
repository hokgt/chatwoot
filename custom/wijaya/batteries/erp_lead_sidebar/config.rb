# frozen_string_literal: true

module Wijaya
  module Batteries
    module ErpLeadSidebar
      # Static, Chatwoot-side configuration for the ERP Lead Sidebar battery.
      #
      # This module is the single backend source of truth for:
      #   * the ERPNext endpoint/auth (read from ENV, never hardcode secrets),
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
      module Config
        module_function

        # Frozen ERPNext DocType we create.
        DOCTYPE = 'Lead'

        # Allowed values for the required `status` Select field. Order matches the
        # dev-tex contract. `Lead` is the default.
        STATUS_VALUES = %w[
          Lead Open Replied Opportunity Quotation
          Lost\ Quotation Interested Converted Do\ Not\ Contact
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

        # --- ERPNext connection (read from ENV; secrets never committed) ---------
        # TODO(wijaya): set these in the deployment environment. The sidebar/draft
        # works fully without them; only "Create Lead" needs a configured ERP.
        def erp_base_url
          ENV['WIJAYA_ERP_BASE_URL'].presence
        end

        def erp_api_key
          ENV['WIJAYA_ERP_API_KEY'].presence
        end

        def erp_api_secret
          ENV['WIJAYA_ERP_API_SECRET'].presence
        end

        # True only when every piece needed to reach ERPNext is present.
        def erp_configured?
          erp_base_url.present? && erp_api_key.present? && erp_api_secret.present?
        end

        def status_allowed?(value)
          STATUS_VALUES.include?(value.to_s)
        end
      end
    end
  end
end
