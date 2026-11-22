<script setup>
import { ref } from 'vue'
import Checkbox from "../../../Checkbox.vue";

const props = defineProps({
  platform: String,
  config: Object,
})

const config = ref(props.config)
</script>

<template>
  <div id="videotoolbox-encoder" class="config-page">
    <!-- Presets -->
    <div class="mb-3">
      <label for="vt_coder" class="form-label">{{ $t('config.vt_coder') }}</label>
      <select id="vt_coder" class="form-select" v-model="config.vt_coder">
        <option value="auto">{{ $t('_common.auto') }}</option>
        <option value="cabac">{{ $t('config.coder_cabac') }}</option>
        <option value="cavlc">{{ $t('config.coder_cavlc') }}</option>
      </select>
    </div>
    <Checkbox class="mb-3"
              id="vt_realtime"
              desc=""
              locale-prefix="config"
              v-model="config.vt_realtime"
              default="true"
    ></Checkbox>
    <div class="mb-3">
      <label for="vt_max_frame_delay" class="form-label">{{ $t('config.vt_max_frame_delay') }}</label>
      <input type="number" min="-1" class="form-control" id="vt_max_frame_delay" placeholder="-1"
             v-model="config.vt_max_frame_delay" />
      <div class="form-text">{{ $t('config.vt_max_frame_delay_desc') }}</div>
    </div>
  </div>
</template>
