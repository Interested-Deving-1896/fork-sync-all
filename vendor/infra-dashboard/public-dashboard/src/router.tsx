import {QueryClient} from '@tanstack/react-query';
import {createRouter} from '@tanstack/react-router';
import {routeTree} from './routeTree.gen';

export function getRouter() {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        gcTime: 10 * 60 * 1000,
        retry: 2,
        staleTime: 5 * 60 * 1000,
      },
    },
  });

  const router = createRouter({
    context: {queryClient},
    defaultPreload: 'intent',
    defaultPreloadStaleTime: 0,
    routeTree,
    scrollRestoration: true,
  });

  return router;
}

declare module '@tanstack/react-router' {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
