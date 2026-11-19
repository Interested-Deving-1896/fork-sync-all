import tailwindcss from '@tailwindcss/vite';
import {devtools} from '@tanstack/devtools-vite';
import {TanStackRouterVite} from '@tanstack/router-plugin/vite';
import viteReact from '@vitejs/plugin-react';
import {defineConfig, loadEnv} from 'vite';
import {VitePWA} from 'vite-plugin-pwa';

const config = defineConfig(({mode}) => {
  const env = loadEnv(mode, process.cwd(), '');
  const appName = env.VITE_APP_NAME || 'Infra Dashboard';
  // short_name: first word of appName, max 12 chars (PWA install banner limit)
  const shortName = appName.split(' ')[0].slice(0, 12);

  return {
  plugins: [
    devtools(),
    tailwindcss(),
    TanStackRouterVite({autoCodeSplitting: true}),
    viteReact(),
    VitePWA({
      devOptions: {enabled: false},
      includeAssets: ['favicon.ico', 'icon.svg'],
      manifest: {
        background_color: '#09090b',
        description: env.VITE_APP_DESCRIPTION || 'Infrastructure dashboard — mirror status, package search, build health.',
        display: 'standalone',
        icons: [
          {purpose: 'any maskable', sizes: '192x192', src: 'icon-192.png', type: 'image/png'},
          {purpose: 'any maskable', sizes: '512x512', src: 'icon-512.png', type: 'image/png'},
        ],
        name: appName,
        short_name: shortName,
        start_url: '/',
        theme_color: '#09090b',
      },
      registerType: 'autoUpdate',
      workbox: {
        // Cache static assets aggressively, API responses minimally
        globPatterns: ['**/*.{js,css,html,ico,svg,woff2}'],
        runtimeCaching: [
          {
            handler: 'NetworkFirst',
            options: {cacheName: 'api-cache', networkTimeoutSeconds: 5},
            urlPattern: ({url}) => url.pathname.startsWith('/api'),
          },
        ],
      },
    }),
  ],
  resolve: {alias: {'@': '/src'}, tsconfigPaths: true},
  };
});

export default config;
