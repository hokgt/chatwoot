<script setup>
// Marine AI feature wrapper. Mirrors Captain's page route view: renders the
// active Marine section (FAQs, Knowledge Base, Scenarios, Playground, Inboxes,
// Tools, Settings) inside a full-height shell.
</script>

<template>
  <div class="flex w-full h-full min-h-0">
    <section class="flex flex-1 h-full px-0 overflow-hidden bg-n-surface-1">
      <router-view />
    </section>
  </div>
</template>
