import { describe, it, expect } from 'vitest';
import {
  extractConversationParticipants,
  isConversationParticipant,
  buildCustomRolePayload,
} from '../permissions';

describe('custom_roles permissions helpers', () => {
  describe('extractConversationParticipants', () => {
    it('prefers meta.participants', () => {
      const conversation = {
        meta: { participants: [{ id: 1 }] },
        participants: [{ id: 2 }],
        conversation_participants: [{ id: 3 }],
      };
      expect(extractConversationParticipants(conversation)).toEqual([
        { id: 1 },
      ]);
    });

    it('falls back to participants then conversation_participants', () => {
      expect(
        extractConversationParticipants({ participants: [{ id: 2 }] })
      ).toEqual([{ id: 2 }]);
      expect(
        extractConversationParticipants({
          conversation_participants: [{ user_id: 3 }],
        })
      ).toEqual([{ user_id: 3 }]);
    });

    it('returns an empty array when no participants are present', () => {
      expect(extractConversationParticipants({ meta: {} })).toEqual([]);
    });
  });

  describe('isConversationParticipant', () => {
    it('matches on participant id', () => {
      const conversation = { meta: { participants: [{ id: 5 }] } };
      expect(isConversationParticipant(conversation, 5)).toBe(true);
    });

    it('matches on participant user_id', () => {
      const conversation = {
        conversation_participants: [{ user_id: 8 }],
      };
      expect(isConversationParticipant(conversation, 8)).toBe(true);
    });

    it('returns false when the user is not a participant', () => {
      const conversation = { participants: [{ id: 1 }, { user_id: 2 }] };
      expect(isConversationParticipant(conversation, 99)).toBe(false);
    });

    it('returns false when there are no participants', () => {
      expect(isConversationParticipant({ meta: {} }, 1)).toBe(false);
    });
  });

  describe('buildCustomRolePayload', () => {
    it('wraps the custom role object under the custom_role key', () => {
      const role = { name: 'Support', permissions: ['conversation_manage'] };
      expect(buildCustomRolePayload(role)).toEqual({ custom_role: role });
    });
  });
});
