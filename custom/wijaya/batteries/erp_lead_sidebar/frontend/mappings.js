// WIJAYA_CUSTOM_START erp_lead_sidebar
// Chatwoot-owned mapping config. Values must be exact ERP document names.
// Keep UI usable offline: these are not fetched from ERP metadata at render time.

// The agent -> ERP User mapping has been removed: the ERP Lead owner is never derived
// from an id/name mapping. It is set server-side by the erp_lead_owner_sync battery from
// the conversation's committed assignee email (validated against ERP) after the Lead
// links, so the sidebar neither offers nor sends an owner value.

export const SOURCE_MAPPING = {
  whatsapp: 'WhatsApp',
};

export const CAMPAIGN_MAPPING = {
  // Example: 'source_id:120245168020850258': 'Online Store ',
};

export const INDUSTRY_OPTIONS = [
  // Add exact ERP Industry Type names here, e.g. 'Garment'
];

export const TERRITORY_OPTIONS = [
  // Add exact ERP Territory names here, e.g. 'JAWA TENGAH'
];

export const UTM_SOURCE_OPTIONS = ['WhatsApp'];

export const UTM_CAMPAIGN_OPTIONS = [
  // Add exact ERP UTM Campaign names here, e.g. 'Online Store '
];
// WIJAYA_CUSTOM_END erp_lead_sidebar
