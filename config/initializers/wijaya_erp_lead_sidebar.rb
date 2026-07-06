# frozen_string_literal: true

# WIJAYA_CUSTOM_START erp_lead_sidebar
# Loads the ERP Lead Sidebar battery. The model depends on ApplicationRecord, so
# load inside to_prepare like other Wijaya custom models under custom/.
Rails.application.config.to_prepare do
  require Rails.root.join('custom/wijaya/batteries/erp_lead_sidebar/config').to_s
  require Rails.root.join('custom/wijaya/batteries/erp_lead_sidebar/lead_draft').to_s
  require Rails.root.join('custom/wijaya/batteries/erp_lead_sidebar/payload_builder').to_s
  require Rails.root.join('custom/wijaya/batteries/erp_lead_sidebar/sync_service').to_s
end
# WIJAYA_CUSTOM_END erp_lead_sidebar
