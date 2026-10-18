<script>
import { useAlert } from 'dashboard/composables';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

// Post-creation configuration for a native WeCom (微信客服) inbox. The inbox is created
// with only Corp ID + Token + EncodingAESKey; the corp-scoped callback is verified in the
// 微信客服 console first, and only then does WeCom reveal the Secret. This panel surfaces
// the corp-scoped Callback URL for that verification step and lets the agent save the
// Secret (and, if they manage multiple KF accounts, the Open KF ID) afterwards.
export default {
  components: {
    SettingsFieldSection,
    NextButton,
  },
  props: {
    inbox: {
      type: Object,
      default: () => ({}),
    },
  },
  data() {
    return {
      // The Secret is never serialized back to the client, so it always starts blank and
      // is only sent when the agent types a new one. The Open KF ID is serialized, so it
      // is preserved and displayed, and is only sent when present.
      secret: '',
      openKfid: this.inbox.open_kfid || '',
      isUpdating: false,
    };
  },
  computed: {
    callbackUrl() {
      return `${window.location.origin}/webhooks/wecom/${this.inbox.corp_id}`;
    },
  },
  methods: {
    async updateWecomConfiguration() {
      // Fail-closed: only send a credential the agent actually provided. A blank Secret
      // must never be sent (it would wipe the stored one on an Open KF ID-only save),
      // and a blank Open KF ID must never blank the stored one. With nothing entered we
      // do not dispatch at all.
      const channel = {};
      const secret = this.secret.trim();
      const openKfid = this.openKfid.trim();
      if (secret) {
        channel.secret = secret;
      }
      if (openKfid) {
        channel.open_kfid = openKfid;
      }
      if (Object.keys(channel).length === 0) {
        return;
      }

      this.isUpdating = true;
      try {
        await this.$store.dispatch('inboxes/updateInbox', {
          id: this.inbox.id,
          formData: false,
          channel,
        });
        // Never keep the plaintext Secret in the component after it is persisted.
        this.secret = '';
        useAlert(this.$t('WECOM_INBOX.CONFIG.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(this.$t('WECOM_INBOX.CONFIG.API.ERROR_MESSAGE'));
      } finally {
        this.isUpdating = false;
      }
    },
  },
};
</script>

<template>
  <div>
    <SettingsFieldSection
      :label="$t('WECOM_INBOX.CONFIG.CALLBACK.TITLE')"
      :help-text="$t('WECOM_INBOX.CONFIG.CALLBACK.SUBTITLE')"
    >
      <woot-code :script="callbackUrl" />
    </SettingsFieldSection>

    <SettingsFieldSection
      :label="$t('WECOM_INBOX.CONFIG.GUIDANCE.TITLE')"
      :help-text="$t('WECOM_INBOX.CONFIG.GUIDANCE.BODY')"
    />

    <SettingsFieldSection :label="$t('WECOM_INBOX.CONFIG.SECRET.LABEL')">
      <woot-input
        v-model="secret"
        type="password"
        class="w-full [&>input]:!mb-0"
        :placeholder="$t('WECOM_INBOX.CONFIG.SECRET.PLACEHOLDER')"
      />
    </SettingsFieldSection>

    <SettingsFieldSection :label="$t('WECOM_INBOX.CONFIG.OPEN_KFID.LABEL')">
      <div class="flex flex-1 justify-between items-center gap-2">
        <woot-input
          v-model="openKfid"
          type="text"
          class="flex-1 [&>input]:!mb-0"
          :placeholder="$t('WECOM_INBOX.CONFIG.OPEN_KFID.PLACEHOLDER')"
        />
        <NextButton
          :is-loading="isUpdating"
          :label="$t('WECOM_INBOX.CONFIG.SAVE_BUTTON')"
          @click="updateWecomConfiguration"
        />
      </div>
    </SettingsFieldSection>
  </div>
</template>
