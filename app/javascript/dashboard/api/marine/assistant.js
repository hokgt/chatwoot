import ApiClient from '../ApiClient';

class MarineAssistant extends ApiClient {
  constructor() {
    super('marine/assistants', { accountScoped: true });
  }
}

export default new MarineAssistant();
