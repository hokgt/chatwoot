import marineDocumentAPI from '../../marine/document';
import ApiClient from '../../ApiClient';

describe('#MarineDocumentAPI', () => {
  it('creates correct instance', () => {
    expect(marineDocumentAPI).toBeInstanceOf(ApiClient);
    expect(marineDocumentAPI).toHaveProperty('get');
    expect(marineDocumentAPI).toHaveProperty('create');
    expect(marineDocumentAPI).toHaveProperty('sync');
    expect(marineDocumentAPI).toHaveProperty('delete');
  });

  describe('#create', () => {
    const originalAxios = window.axios;
    const axiosMock = {
      post: vi.fn(() => Promise.resolve()),
      get: vi.fn(() => Promise.resolve()),
      delete: vi.fn(() => Promise.resolve()),
    };

    beforeEach(() => {
      window.axios = axiosMock;
    });

    afterEach(() => {
      window.axios = originalAxios;
      vi.clearAllMocks();
    });

    it('posts a JSON document payload for the website workflow', () => {
      marineDocumentAPI.create({
        assistantId: 7,
        name: 'Docs',
        externalLink: 'https://example.com',
        content: 'body',
      });
      expect(axiosMock.post).toHaveBeenCalledWith(marineDocumentAPI.url, {
        document: {
          assistant_id: 7,
          name: 'Docs',
          external_link: 'https://example.com',
          content: 'body',
        },
      });
    });

    it('forwards FormData untouched for the SOP workflow', () => {
      const formData = new FormData();
      formData.append('document[source_kind]', 'sop_document');
      formData.append('document[assistant_id]', '7');
      formData.append('document[name]', 'SOP');
      formData.append(
        'document[source_file]',
        new Blob(['pdf'], { type: 'application/pdf' })
      );

      marineDocumentAPI.create(formData);

      expect(axiosMock.post).toHaveBeenCalledWith(
        marineDocumentAPI.url,
        formData
      );
      const [, payload] = axiosMock.post.mock.calls[0];
      expect(payload).toBeInstanceOf(FormData);
      expect(payload.get('document[source_kind]')).toEqual('sop_document');
      expect(payload.get('document[name]')).toEqual('SOP');
    });
  });
});
