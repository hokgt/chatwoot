/* global axios */
import ApiClient from '../ApiClient';

class MarinePreferences extends ApiClient {
  constructor() {
    super('marine/preferences', { accountScoped: true });
  }

  get() {
    return axios.get(this.url);
  }

  updatePreferences(data) {
    return axios.put(this.url, data);
  }
}

export default new MarinePreferences();
