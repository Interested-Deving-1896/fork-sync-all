'use client';

import {Plus, Search, Shield} from 'lucide-react';
import Link from 'next/link';
import {useCallback, useEffect, useMemo, useState} from 'react';

import {
  getCustomPackages,
  getCustomRepos,
  getMaintainers,
} from '@/app/actions/custom';
import {AddMaintainerDialog} from '@/components/custom/add-maintainer-dialog';
import Loader from '@/components/loader';
import {Badge} from '@/components/ui/badge';
import {Button} from '@/components/ui/button';
import {EmptyState} from '@/components/ui/empty-state';
import {FilterToolbar} from '@/components/ui/filter-toolbar';
import {Input} from '@/components/ui/input';
import {MetadataRow} from '@/components/ui/metadata-row';
import {PageHeader} from '@/components/ui/page-header';
import {useSidebar} from '@/components/ui/sidebar';
import {useInfiniteList} from '@/lib/hooks/use-infinite-list';
import {
  type CustomPackage,
  type CustomRepo,
  isActionError,
  type MaintainerPolicy,
  unwrapOr,
  UserScope,
} from '@/lib/typings';
import {checkScopes, unixToDate} from '@/lib/utils';

interface MaintainerGroup {
  autoQueueAll: boolean;
  oldestGrant: Date | null;
  policies: MaintainerPolicy[];
  username: string;
}

export default function MaintainersListPage() {
  const {scopes, username: currentUser} = useSidebar();
  const isAdmin = useMemo(
    () => checkScopes(scopes, [UserScope.ADMIN]),
    [scopes]
  );

  const [repos, setRepos] = useState<CustomRepo[]>([]);
  const [packages, setPackages] = useState<CustomPackage[]>([]);
  const [search, setSearch] = useState('');
  const [addOpen, setAddOpen] = useState(false);

  const fetchPage = useCallback(async (page: number, size: number) => {
    const r = await getMaintainers(page, size);
    if (isActionError(r)) return r;
    return {items: r.maintainers, totalPages: r.total_pages};
  }, []);

  const {
    hasMore,
    items: policies,
    loading,
    reload,
    sentinelRef,
  } = useInfiniteList<MaintainerPolicy>(fetchPage);

  useEffect(() => {
    if (!isAdmin) return;
    Promise.all([getCustomRepos(), getCustomPackages()]).then(([r, p]) => {
      setRepos(unwrapOr(r, {repos: [], total_items: 0, total_pages: 0}).repos);
      setPackages(
        unwrapOr(p, {
          custom_packages: [],
          total_items: 0,
          total_pages: 0,
        }).custom_packages
      );
    });
  }, [isAdmin]);

  const groups = useMemo(() => groupByUsername(policies), [policies]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return groups;
    return groups.filter(g => g.username.toLowerCase().includes(q));
  }, [groups, search]);

  if (!isAdmin) {
    return (
      <EmptyState
        description="Maintainer management is restricted to administrators."
        icon={<Shield />}
        title="Admin access required"
      />
    );
  }

  const initialLoading = loading && policies.length === 0;

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        actions={
          <Button onClick={() => setAddOpen(true)} size="sm" variant="brand">
            <Plus className="size-3.5" />
            Add maintainer
          </Button>
        }
        description="Users granted maintainer privileges on specific custom packages."
        title="Maintainers"
      />

      <FilterToolbar>
        <div className="relative w-full max-w-sm">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="h-8 pl-8"
            onChange={e => setSearch(e.target.value)}
            placeholder="Search by username…"
            value={search}
          />
        </div>
      </FilterToolbar>

      {initialLoading ? (
        <Loader animate text="Loading maintainers…" />
      ) : filtered.length === 0 ? (
        <EmptyState
          description={
            policies.length === 0
              ? 'No maintainer policies have been granted yet.'
              : 'No maintainers match the search.'
          }
          icon={<Shield />}
          title={policies.length === 0 ? 'No maintainers' : 'No matches'}
        />
      ) : (
        <ul className="flex flex-col divide-y rounded-lg border">
          {filtered.map(group => (
            <li key={group.username}>
              <Link
                className="flex items-center gap-4 px-4 py-3 transition-colors hover:bg-muted/50"
                href={`/dashboard/custom/maintainers/${encodeURIComponent(group.username)}`}
              >
                <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                  <span className="truncate text-sm font-medium">
                    {group.username}
                  </span>
                  <MetadataRow
                    items={[
                      {
                        value: `${group.policies.length} package${group.policies.length === 1 ? '' : 's'}`,
                      },
                      group.oldestGrant && {
                        label: 'since',
                        value: group.oldestGrant.toLocaleDateString(),
                      },
                    ]}
                  />
                </div>
                <Badge variant={group.autoQueueAll ? 'info' : 'muted'}>
                  {group.autoQueueAll ? 'auto queue' : 'manual'}
                </Badge>
                <span className="text-xs text-muted-foreground">View →</span>
              </Link>
            </li>
          ))}
        </ul>
      )}

      {hasMore && (
        <div
          className="py-2 text-center text-xs text-muted-foreground"
          ref={sentinelRef}
        >
          {loading ? 'Loading more…' : ''}
        </div>
      )}

      <AddMaintainerDialog
        currentUser={currentUser}
        onOpenChange={setAddOpen}
        onSuccess={reload}
        open={addOpen}
        packages={packages}
        repos={repos}
      />
    </div>
  );
}

function groupByUsername(policies: MaintainerPolicy[]): MaintainerGroup[] {
  const map = new Map<string, MaintainerPolicy[]>();
  for (const p of policies) {
    const arr = map.get(p.username) ?? [];
    arr.push(p);
    map.set(p.username, arr);
  }
  return Array.from(map.entries())
    .map(([username, ps]) => {
      const dates: Date[] = [];
      for (const p of ps) {
        const d = unixToDate(p.granted_at);
        if (!isNaN(d.getTime())) dates.push(d);
      }
      return {
        autoQueueAll: ps.every(p => p.auto_queue),
        oldestGrant: dates.length
          ? new Date(Math.min(...dates.map(d => d.getTime())))
          : null,
        policies: ps,
        username,
      } satisfies MaintainerGroup;
    })
    .sort((a, b) => a.username.localeCompare(b.username));
}
