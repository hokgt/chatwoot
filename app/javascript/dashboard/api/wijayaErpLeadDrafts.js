/* global axios */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import ApiClient from './ApiClient';

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

  options() {
    return axios.get(`${this.url}/options`);
  }
}

export default new WijayaErpLeadDraftsAPI();
// WIJAYA_CUSTOM_END erp_lead_sidebar
