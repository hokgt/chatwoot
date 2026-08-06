/* global axios */
import ApiClient from '../ApiClient';

class MarineLLMSettings extends ApiClient {
  constructor() {
    super('marine/llm_settings', { accountScoped: true });
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

export default new MarineLLMSettings();
