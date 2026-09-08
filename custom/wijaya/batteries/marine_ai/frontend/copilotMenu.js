/**
 * Battery-owned Copilot menu filter. Marine natural-language query is scoped to
 * the Marine page for a later release, so the global "Ask Copilot" entry is
 * withheld for Marine-linked conversations. Every other conversation keeps the
 * native Captain menu untouched. Draft/improve/summarize actions still route to
 * Marine through the useCaptain adapter.
 *
 * @param {Array<Object>} items - The native Copilot general menu items.
 * @param {Object} [context]
 * @param {boolean} [context.isMarineConversation] - Whether the current inbox is
 *   linked to a Marine assistant.
 * @returns {Array<Object>} The (possibly filtered) menu items.
 */
export function filterMarineCopilotMenu(items, { isMarineConversation } = {}) {
  if (!isMarineConversation) return items;
  return items.filter(item => item.key !== 'ask_copilot');
}
