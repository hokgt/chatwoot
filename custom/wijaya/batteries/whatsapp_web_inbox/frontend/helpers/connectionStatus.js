// Maps a connector session status to its i18n label using LITERAL keys only (so the
// vue-i18n no-dynamic-keys rule stays satisfied). Shared by the wizard and the panel.
export function connectionStatusLabel(t, status, connectorAvailable) {
  if (!connectorAvailable) return t('WHATSAPP_WEB_INBOX.STATUS.UNAVAILABLE');

  switch (status) {
    case 'unconfigured':
      return t('WHATSAPP_WEB_INBOX.STATUS.UNCONFIGURED');
    case 'waiting_for_qr':
      return t('WHATSAPP_WEB_INBOX.STATUS.WAITING_FOR_QR');
    case 'connecting':
      return t('WHATSAPP_WEB_INBOX.STATUS.CONNECTING');
    case 'connected':
      return t('WHATSAPP_WEB_INBOX.STATUS.CONNECTED');
    case 'disconnected':
      return t('WHATSAPP_WEB_INBOX.STATUS.DISCONNECTED');
    case 'logged_out':
      return t('WHATSAPP_WEB_INBOX.STATUS.LOGGED_OUT');
    case 'authentication_failed':
      return t('WHATSAPP_WEB_INBOX.STATUS.AUTHENTICATION_FAILED');
    case 'replaced':
      return t('WHATSAPP_WEB_INBOX.STATUS.REPLACED');
    case 'error':
      return t('WHATSAPP_WEB_INBOX.STATUS.ERROR');
    default:
      return t('WHATSAPP_WEB_INBOX.STATUS.PENDING');
  }
}

export default connectionStatusLabel;
