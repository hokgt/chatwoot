<script setup>
defineProps({
  title: {
    type: String,
    default: '',
  },
  description: {
    type: String,
    default: '',
  },
});
</script>

<template>
  <main class="flex-1 p-6 overflow-auto">
    <section class="max-w-5xl mx-auto space-y-4">
      <div>
        <h1 class="text-2xl font-semibold text-n-slate-12">
          {{ title }}
        </h1>
        <p v-if="description" class="text-sm text-n-slate-11">
          {{ description }}
        </p>
      </div>
      <slot />
    </section>
  </main>
</template>
