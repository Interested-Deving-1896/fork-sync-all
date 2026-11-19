import {useQuery} from '@tanstack/react-query';
import {createFileRoute} from '@tanstack/react-router';

import MirrorslistTable from '@/components/MirrorslistTable';
import {SiteCardHeader} from '@/components/SiteCardHeader';
import {Card, CardContent} from '@/components/ui/card';
import {getMirrorsData} from '@/lib/server/actions';

export const Route = createFileRoute('/mirrors')({
  component: MirrorsPage,
  head: () => ({
    meta: [{title: `${import.meta.env.VITE_APP_NAME || 'Package Dashboard'} | Mirrors List`}],
  }),
});

function MirrorsPage() {
  const appName = import.meta.env.VITE_APP_NAME || 'Package Dashboard';
  const {data, isLoading, error} = useQuery({
    queryFn: getMirrorsData,
    queryKey: ['mirrors'],
    staleTime: 10 * 60 * 1000,
  });

  return (
    <main className="container mx-auto p-2 sm:p-4 md:p-8">
      <Card>
        <SiteCardHeader
          description={`List of ${appName} package repository mirrors.`}
          navTarget="packages"
          title={`${appName} Package Repository Mirrors`}
        />
        <CardContent>
          {isLoading && <p className="text-muted-foreground">Loading mirrors…</p>}
          {error && <p className="text-destructive">Failed to load mirror data.</p>}
          {data && <MirrorslistTable baselines={data.baselines} mirrors={data.mirrors} />}
        </CardContent>
      </Card>
    </main>
  );
}
