import type {NextConfig} from 'next';

const nextConfig: NextConfig = {
  devIndicators: {
    position: 'bottom-right',
  },
  poweredByHeader: false,
  reactStrictMode: false,
  async redirects() {
    return [
      {
        destination: '/api/logs/:march/:pkgbase',
        has: [
          {
            key: 'raw',
            type: 'query',
          },
        ],
        permanent: false,
        source: '/dashboard/logs/:march/:pkgbase',
      },
      {
        destination: '/dashboard/package-list',
        permanent: false,
        source: '/dashboard',
      },
    ];
  },
};

export default nextConfig;
