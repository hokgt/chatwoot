import marineDocumentAPI from '../../marine/document';
import ApiClient from '../../ApiClient';

describe('#MarineDocumentAPI', () => {
  it('creates correct instance', () => {
    expect(marineDocumentAPI).toBeInstanceOf(ApiClient);
    expect(marineDocumentAPI).toHaveProperty('get');
    expect(marineDocumentAPI).toHaveProperty('create');
    expect(marineDocumentAPI).toHaveProperty('productFamilies');
    expect(marineDocumentAPI).toHaveProperty('createProductCatalog');
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

  describe('#productFamilies', () => {
    const originalAxios = window.axios;
    const axiosMock = { get: vi.fn(() => Promise.resolve()) };

    beforeEach(() => {
      window.axios = axiosMock;
    });
    afterEach(() => {
      window.axios = originalAxios;
      vi.clearAllMocks();
    });

    it('gets the bounded product-family list with query params', () => {
      marineDocumentAPI.productFamilies({ query: 'pump', limit: 5 });
      expect(axiosMock.get).toHaveBeenCalledWith(
        `${marineDocumentAPI.url}/product_families`,
        { params: { query: 'pump', limit: 5 } }
      );
    });
  });

  describe('#createProductCatalog', () => {
    const originalAxios = window.axios;
    const axiosMock = { post: vi.fn(() => Promise.resolve()) };

    beforeEach(() => {
      window.axios = axiosMock;
    });
    afterEach(() => {
      window.axios = originalAxios;
      vi.clearAllMocks();
    });

    it('posts the exact flat multipart contract with replace=false', () => {
      const file = new File(['pdf'], 'catalog.pdf', {
        type: 'application/pdf',
      });
      marineDocumentAPI.createProductCatalog({
        assistantId: 7,
        productFamilyCode: 'PUMP-100',
        name: 'Pump Catalog',
        file,
        replace: false,
      });

      expect(axiosMock.post).toHaveBeenCalledTimes(1);
      const [url, payload] = axiosMock.post.mock.calls[0];
      expect(url).toBe(`${marineDocumentAPI.url}/product_catalog`);
      expect(payload).toBeInstanceOf(FormData);
      expect(payload.get('assistant_id')).toBe('7');
      expect(payload.get('product_family_code')).toBe('PUMP-100');
      expect(payload.get('name')).toBe('Pump Catalog');
      expect(payload.get('primary_catalog')).toBe('true');
      expect(payload.get('replace')).toBe('false');
      expect(payload.get('file')).toBe(file);
      // Nothing from the website/SOP contracts must leak in.
      expect(payload.has('document[source_kind]')).toBe(false);
      expect(payload.has('source_kind')).toBe(false);
    });

    it('omits the optional name and sends replace=true when confirmed', () => {
      const file = new File(['pdf'], 'catalog.pdf', {
        type: 'application/pdf',
      });
      marineDocumentAPI.createProductCatalog({
        assistantId: 7,
        productFamilyCode: 'PUMP-100',
        file,
        replace: true,
      });

      const [, payload] = axiosMock.post.mock.calls[0];
      expect(payload.has('name')).toBe(false);
      expect(payload.get('replace')).toBe('true');
      expect(payload.get('primary_catalog')).toBe('true');
    });
  });
});
