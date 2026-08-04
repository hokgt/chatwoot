import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';

export const CONVERSATION_PERMISSIONS = [
  'conversation_manage',
  'conversation_unassigned_manage',
  'conversation_participating_manage',
];

export const customRoleInstallationTypes = [
  INSTALLATION_TYPES.CLOUD,
  INSTALLATION_TYPES.ENTERPRISE,
  INSTALLATION_TYPES.COMMUNITY,
];

export const canManageConversationAssignment = permissions =>
  permissions.includes('administrator') ||
  permissions.includes('conversation_manage');

export const splitConversationPermission = permissions => ({
  selectedConversationPermission:
    permissions.find(permission =>
      CONVERSATION_PERMISSIONS.includes(permission)
    ) || null,
  selectedPermissions: permissions.filter(
    permission => !CONVERSATION_PERMISSIONS.includes(permission)
  ),
});

export const buildCustomRolePermissions = (
  selectedConversationPermission,
  selectedPermissions
) => [selectedConversationPermission, ...selectedPermissions].filter(Boolean);

export const nonConversationPermissions = permissions =>
  permissions.filter(
    permission => !CONVERSATION_PERMISSIONS.includes(permission)
  );

export const customRolesBehindPaywall = () => false;

export const extractConversationParticipants = conversation =>
  conversation.meta?.participants ||
  conversation.participants ||
  conversation.conversation_participants ||
  [];

export const isConversationParticipant = (conversation, currentUserId) =>
  extractConversationParticipants(conversation).some(
    participant =>
      participant?.id === currentUserId ||
      participant?.user_id === currentUserId
  );

export const buildCustomRolePayload = customRole => ({
  custom_role: customRole,
});
