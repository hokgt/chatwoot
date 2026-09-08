import { buildMarineSidebarSection } from '../sidebar/marineSidebarSection';

// Marine sidebar RBAC: Inboxes, LLM Settings (AI Provider) and Settings are
// administrator-only. Non-administrators — plain agents AND every custom role
// (supervisor/marketing/sales) — resolve to isAdmin === false and must not see
// those three entries, while the other Marine items stay visible.
describe('buildMarineSidebarSection', () => {
  const t = key => key;
  const accountScopedRoute = (name, params) => ({ name, params });

  const ADMIN_ONLY = ['Inboxes', 'LLM Settings', 'Settings'];
  const ALWAYS_VISIBLE = [
    'FAQs',
    'Documents',
    'Scenarios',
    'Copilot',
    'Playground',
  ];

  const childNames = section => section.children.map(child => child.name);

  it('shows all entries (including the three admin-only ones) for an administrator', () => {
    const section = buildMarineSidebarSection({
      t,
      accountScopedRoute,
      isAdmin: true,
    });

    const names = childNames(section);
    ALWAYS_VISIBLE.forEach(name => expect(names).toContain(name));
    ADMIN_ONLY.forEach(name => expect(names).toContain(name));
  });

  it('hides Inboxes, LLM Settings and Settings for a non-administrator', () => {
    const section = buildMarineSidebarSection({
      t,
      accountScopedRoute,
      isAdmin: false,
    });

    const names = childNames(section);
    ALWAYS_VISIBLE.forEach(name => expect(names).toContain(name));
    ADMIN_ONLY.forEach(name => expect(names).not.toContain(name));
  });

  it('defaults to hiding the admin-only entries when isAdmin is omitted (fail-closed)', () => {
    const section = buildMarineSidebarSection({ t, accountScopedRoute });

    const names = childNames(section);
    ADMIN_ONLY.forEach(name => expect(names).not.toContain(name));
    expect(names).toEqual(ALWAYS_VISIBLE);
  });
});
