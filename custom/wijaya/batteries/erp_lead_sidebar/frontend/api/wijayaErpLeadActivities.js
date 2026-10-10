/* global axios */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import ApiClient from 'dashboard/api/ApiClient';

// Nested under the ERP Lead draft (addressed by conversation display_id). Each
// read endpoint is independent so the client can lazy-load it at the dropdown
// level and hit only its own ERP dependency:
//   GET  .../erp_lead_drafts/:conversationId/lead_activities/meta
//        (default_date only; issues NO ERP request)
//   GET  .../erp_lead_drafts/:conversationId/lead_activities/activity_options
//   GET  .../erp_lead_drafts/:conversationId/lead_activities/person_in_charge_options
//   POST .../erp_lead_drafts/:conversationId/lead_activities
class WijayaErpLeadActivitiesAPI extends ApiClient {
  constructor() {
    super('wijaya/erp_lead_drafts', { accountScoped: true });
  }

  fetchMeta(conversationId) {
    return axios.get(`${this.url}/${conversationId}/lead_activities/meta`);
  }

  fetchActivityOptions(conversationId) {
    return axios.get(
      `${this.url}/${conversationId}/lead_activities/activity_options`
    );
  }

  fetchPersonInChargeOptions(conversationId) {
    return axios.get(
      `${this.url}/${conversationId}/lead_activities/person_in_charge_options`
    );
  }

  create(conversationId, payload) {
    return axios.post(`${this.url}/${conversationId}/lead_activities`, payload);
  }
}

export default new WijayaErpLeadActivitiesAPI();
// WIJAYA_CUSTOM_END erp_lead_sidebar
