import { defineConfig } from 'vite';
import checker from 'vite-plugin-checker';

export default defineConfig({
  build: {
    lib: {
      // Could also be a dictionary or array of multiple entry points
      entry: './src/main.ts',
      name: 'quasar-web-client',
      // the proper extensions will be added
      fileName: 'main',
      formats: [ 'es' ],
    },
  },
  plugins: [
    checker({
      typescript: true,
    }),
  ],
});
