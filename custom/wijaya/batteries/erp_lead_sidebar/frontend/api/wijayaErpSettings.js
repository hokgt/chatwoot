/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

// WIJAYA_CUSTOM erp_lead_sidebar
// Admin API for the account-scoped ERPNext connection settings (singleton
// resource). Never receives the raw key/secret back — only masked/presence
// metadata from the controller.
class WijayaErpSettingsAPI extends ApiClient {
  constructor() {
    super('wijaya/erp_setting', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  update(data) {
    return axios.put(this.url, data);
  }

  test(data) {
    return axios.post(`${this.url}/test`, data);
  }
}

export default new WijayaErpSettingsAPI();
