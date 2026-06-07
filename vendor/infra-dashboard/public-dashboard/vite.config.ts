import tailwindcss from '@tailwindcss/vite';
import {devtools} from '@tanstack/devtools-vite';
import {TanStackRouterVite} from '@tanstack/router-plugin/vite';
import viteReact from '@vitejs/plugin-react';
import {defineConfig} from 'vite';
import {VitePWA} from 'vite-plugin-pwa';

const config = defineConfig({
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
        description: 'OpenOS Project infrastructure dashboard — mirror status, package search, build health.',
        display: 'standalone',
        icons: [
          {purpose: 'any maskable', sizes: '192x192', src: 'icon-192.png', type: 'image/png'},
          {purpose: 'any maskable', sizes: '512x512', src: 'icon-512.png', type: 'image/png'},
        ],
        name: 'OpenOS Infra Dashboard',
        short_name: 'OSP Dashboard',
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
});

export default config;
