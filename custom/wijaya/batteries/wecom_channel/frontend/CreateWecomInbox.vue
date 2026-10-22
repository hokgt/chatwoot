<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required, minLength, maxLength } from '@vuelidate/validators';
import router from 'dashboard/routes/index';
import PageHeader from 'dashboard/routes/dashboard/settings/SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

// EncodingAESKey is a fixed 43-character Base64 string per the WeCom spec.
const ENCODING_AES_KEY_LENGTH = 43;

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: '',
      corpId: '',
      token: '',
      encodingAesKey: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    channelName: { required },
    corpId: { required },
    token: { required },
    encodingAesKey: {
      required,
      minLength: minLength(ENCODING_AES_KEY_LENGTH),
      maxLength: maxLength(ENCODING_AES_KEY_LENGTH),
    },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const wecomChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            name: this.channelName?.trim(),
            channel: {
              type: 'wecom',
              corp_id: this.corpId,
              token: this.token,
              encoding_aes_key: this.encodingAesKey,
            },
          }
        );

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: wecomChannel.id,
          },
        });
      } catch (error) {
        useAlert(this.$t('WECOM_INBOX.CREATE.API.ERROR_MESSAGE'));
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('WECOM_INBOX.CREATE.TITLE')"
      :header-content="$t('WECOM_INBOX.CREATE.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('WECOM_INBOX.CREATE.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="$t('WECOM_INBOX.CREATE.CHANNEL_NAME.PLACEHOLDER')"
            @blur="v$.channelName.$touch"
          />
          <span v-if="v$.channelName.$error" class="message">{{
            $t('WECOM_INBOX.CREATE.CHANNEL_NAME.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.corpId.$error }">
          {{ $t('WECOM_INBOX.CREATE.CORP_ID.LABEL') }}
          <input
            v-model="corpId"
            type="text"
            :placeholder="$t('WECOM_INBOX.CREATE.CORP_ID.PLACEHOLDER')"
            @blur="v$.corpId.$touch"
          />
          <span v-if="v$.corpId.$error" class="message">{{
            $t('WECOM_INBOX.CREATE.CORP_ID.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.token.$error }">
          {{ $t('WECOM_INBOX.CREATE.TOKEN.LABEL') }}
          <input
            v-model="token"
            type="text"
            :placeholder="$t('WECOM_INBOX.CREATE.TOKEN.PLACEHOLDER')"
            @blur="v$.token.$touch"
          />
          <span v-if="v$.token.$error" class="message">{{
            $t('WECOM_INBOX.CREATE.TOKEN.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.encodingAesKey.$error }">
          {{ $t('WECOM_INBOX.CREATE.ENCODING_AES_KEY.LABEL') }}
          <input
            v-model="encodingAesKey"
            type="text"
            :placeholder="$t('WECOM_INBOX.CREATE.ENCODING_AES_KEY.PLACEHOLDER')"
            @blur="v$.encodingAesKey.$touch"
          />
          <span v-if="v$.encodingAesKey.$error" class="message">{{
            $t('WECOM_INBOX.CREATE.ENCODING_AES_KEY.ERROR')
          }}</span>
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('WECOM_INBOX.CREATE.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
