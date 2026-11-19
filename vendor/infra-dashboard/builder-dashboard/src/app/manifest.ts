import {MetadataRoute} from 'next';

export default function manifest(): MetadataRoute.Manifest {
  return {
    background_color: '#ffffff',
    description: process.env.NEXT_PUBLIC_APP_DESCRIPTION ?? 'Builder Dashboard',
    display: 'standalone',
    icons: [
      {
        sizes: 'any',
        src: '/favicon.ico',
        type: 'image/x-icon',
      },
    ],
    name: process.env.NEXT_PUBLIC_APP_NAME ?? 'Builder Dashboard',
    short_name: process.env.NEXT_PUBLIC_APP_SHORT_NAME ?? 'Builder Dashboard',
    start_url: '/',
    theme_color: '#3b82f6',
  };
}
