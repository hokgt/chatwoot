/* global axios */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import ApiClient from 'dashboard/api/ApiClient';

// Nested under the ERP Lead draft (addressed by conversation display_id):
//   GET  .../erp_lead_drafts/:conversationId/lead_activities/options
//   POST .../erp_lead_drafts/:conversationId/lead_activities
class WijayaErpLeadActivitiesAPI extends ApiClient {
  constructor() {
    super('wijaya/erp_lead_drafts', { accountScoped: true });
  }

  fetchOptions(conversationId) {
    return axios.get(`${this.url}/${conversationId}/lead_activities/options`);
  }

  create(conversationId, payload) {
    return axios.post(`${this.url}/${conversationId}/lead_activities`, payload);
  }
}

export default new WijayaErpLeadActivitiesAPI();
// WIJAYA_CUSTOM_END erp_lead_sidebar
