/* global axios */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import ApiClient from 'dashboard/api/ApiClient';

class WijayaErpLeadDraftsAPI extends ApiClient {
  constructor() {
    super('wijaya/erp_lead_drafts', { accountScoped: true });
  }

  show(conversationId) {
    return axios.get(`${this.url}/${conversationId}`);
  }

  save(conversationId, fields) {
    return axios.patch(`${this.url}/${conversationId}`, { fields });
  }

  sync(conversationId, fields) {
    return axios.post(`${this.url}/${conversationId}/sync`, { fields });
  }

  // Sets a sticky manual Lead Owner (server-validated against the live ERP User list).
  setOwner(conversationId, owner) {
    return axios.post(`${this.url}/${conversationId}/owner`, { owner });
  }

  // Clears the manual override so the owner follows the assigned agent again.
  resetOwner(conversationId) {
    return axios.post(`${this.url}/${conversationId}/owner`, { reset: true });
  }

  // Re-queues the ERP owner sync for the current desired owner (manual override or
  // assignee) when a previous owner sync is still pending/failed on a linked Lead.
  retryOwner(conversationId) {
    return axios.post(`${this.url}/${conversationId}/owner`, { retry: true });
  }

  options() {
    return axios.get(`${this.url}/options`);
  }
}

export default new WijayaErpLeadDraftsAPI();
// WIJAYA_CUSTOM_END erp_lead_sidebar
