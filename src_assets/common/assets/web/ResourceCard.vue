<template>
    <div class="card">
        <div class="card-body">
            <h2>{{ $t('resource_card.resources') }}</h2>
            <div class="d-flex flex-wrap gap-2 mt-4">
                <a class="btn btn-success" href="https://github.com/jayl-dev/Lumina" target="_blank">
                  <SimpleIcon icon="GitHub" :size="18" class="icon"></SimpleIcon>
                  Lumina on GitHub
                </a>
                <a class="btn btn-info" href="https://github.com/jayl-dev/Lumina/tree/main/docs" target="_blank">
                  <BookOpen :size="18" class="icon"></BookOpen>
                  {{ $t('resource_card.documentation') }}
                </a>
                <a class="btn btn-secondary" href="https://github.com/jayl-dev/Lumina/issues" target="_blank">
                  <CircleHelp :size="18" class="icon"></CircleHelp>
                  Issues
                </a>
            </div>
        </div>
    </div>
    <!-- Legal -->
    <div class="card mt-4">
        <div class="card-body">
            <h2>{{ $t('resource_card.legal') }}</h2>
            <p>{{ $t('resource_card.legal_desc') }}</p>
            <div class="d-flex flex-wrap gap-2 mt-4">
                <a class="btn btn-danger" href="https://github.com/jayl-dev/Lumina/blob/main/LICENSE"
                    target="_blank">
                  <FileText :size="18" class="icon"></FileText>
                  {{ $t('resource_card.license') }}
                </a>
                <a class="btn btn-danger" href="https://github.com/jayl-dev/Lumina/blob/main/NOTICE"
                    target="_blank">
                  <AlertCircle :size="18" class="icon"></AlertCircle>
                  {{ $t('resource_card.third_party_notice') }}
                </a>
            </div>
        </div>
    </div>
</template>

<script>
import {
  AlertCircle,
  BookOpen,
  CircleHelp,
  FileText,
} from '@lucide/vue'
import SimpleIcon from './SimpleIcon.vue'

export default {
  components: {
    SimpleIcon,
    AlertCircle,
    BookOpen,
    CircleHelp,
    FileText,
  },
}
</script>
