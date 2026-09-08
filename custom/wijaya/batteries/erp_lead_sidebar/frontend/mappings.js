// WIJAYA_CUSTOM_START erp_lead_sidebar
// Chatwoot-owned mapping config. Values must be exact ERP document names.
// Keep UI usable offline: these are not fetched from ERP metadata at render time.

// Single battery-owned source of truth for the agent -> ERP User mapping, shared
// verbatim with the backend (lead_activity_person_directory.rb reads the same
// file). Keys are the Chatwoot agent id (as a string) or the agent display name;
// values are exact ERP User.name strings. The committed file is intentionally an
// empty object — real mappings must stay source-controlled and may only be added
// by a future, explicitly approved code change (never hand-edited in a deployed
// copy). JSON object keys are strings, but JS index access coerces a numeric
// assignee.id to its string form, so id/name lookup stays compatible.
import AGENT_ERP_USER_MAP from '../agent_erp_user_map.json';

export const AGENT_TO_ERP_USER = AGENT_ERP_USER_MAP;

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
