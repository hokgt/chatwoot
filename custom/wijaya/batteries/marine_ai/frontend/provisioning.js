/* global axios */
import ApiClient from 'dashboard/api/ApiClient';

class MarineProvisioning extends ApiClient {
  constructor() {
    super('marine/provisioning', { accountScoped: true });
  }

  // Read-only status fetch. Runs no PostgreSQL action server-side.
  getStatus() {
    return axios.get(this.url);
  }

  // Explicit one-time creation. `password` is sent under the filtered `password`
  // param and is never persisted or echoed by the backend.
  create({ databaseName, loginUsername, password }) {
    return axios.post(this.url, {
      provisioning: {
        database_name: databaseName,
        login_username: loginUsername,
        password,
      },
    });
  }

  downgrade() {
    return axios.post(`${this.url}/downgrade`);
  }

  revokeAll() {
    return axios.post(`${this.url}/revoke_all`);
  }

  // Explicit read-only privilege matrix (button-triggered).
  privileges() {
    return axios.get(`${this.url}/privileges`);
  }
}

export default new MarineProvisioning();
