import marineAssistantAPI from '../assistant';
import ApiClient from 'dashboard/api/ApiClient';

describe('#MarineAssistantAPI', () => {
  it('creates correct instance', () => {
    expect(marineAssistantAPI).toBeInstanceOf(ApiClient);
    expect(marineAssistantAPI).toHaveProperty('get');
    expect(marineAssistantAPI).toHaveProperty('playground');
  });

  describe('#playground', () => {
    const originalAxios = window.axios;
    const axiosMock = { post: vi.fn(() => Promise.resolve()) };

    beforeEach(() => {
      window.axios = axiosMock;
    });
    afterEach(() => {
      window.axios = originalAxios;
      vi.clearAllMocks();
    });

    it('posts the message content and the prior turn history', () => {
      marineAssistantAPI.playground({
        assistantId: 7,
        messageContent: 'follow up',
        messageHistory: [{ role: 'user', content: 'earlier' }],
      });

      expect(axiosMock.post).toHaveBeenCalledWith(
        `${marineAssistantAPI.url}/7/playground`,
        {
          assistant: {
            message_content: 'follow up',
            message_history: [{ role: 'user', content: 'earlier' }],
          },
        }
      );
    });

    it('defaults history to an empty array when omitted', () => {
      marineAssistantAPI.playground({
        assistantId: 7,
        messageContent: 'hello',
      });

      expect(axiosMock.post).toHaveBeenCalledWith(
        `${marineAssistantAPI.url}/7/playground`,
        { assistant: { message_content: 'hello', message_history: [] } }
      );
    });
  });
});
