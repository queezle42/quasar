import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    lib: {
      // Could also be a dictionary or array of multiple entry points
      entry: './src/index.ts',
      name: 'quasar-web-client',
      // the proper extensions will be added
      fileName: 'index',
      formats: [ 'es' ],
    },
  },
});
