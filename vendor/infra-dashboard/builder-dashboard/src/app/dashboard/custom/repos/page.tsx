'use client';

import {GitBranch, Search} from 'lucide-react';
import Link from 'next/link';
import {useCallback, useMemo, useState} from 'react';

import {getCustomRepos} from '@/app/actions/custom';
import Loader from '@/components/loader';
import {EmptyState} from '@/components/ui/empty-state';
import {FilterToolbar} from '@/components/ui/filter-toolbar';
import {Input} from '@/components/ui/input';
import {MetadataRow} from '@/components/ui/metadata-row';
import {PageHeader} from '@/components/ui/page-header';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {useInfiniteList} from '@/lib/hooks/use-infinite-list';
import {type CustomRepo, isActionError} from '@/lib/typings';

export default function ReposListPage() {
  const [search, setSearch] = useState('');
  const [archFilter, setArchFilter] = useState('ALL');

  const fetchPage = useCallback(async (page: number, size: number) => {
    const r = await getCustomRepos(page, size);
    if (isActionError(r)) return r;
    return {items: r.repos, totalPages: r.total_pages};
  }, []);

  const {
    hasMore,
    items: repos,
    loading,
    sentinelRef,
  } = useInfiniteList<CustomRepo>(fetchPage);

  const archOptions = useMemo(() => {
    const set = new Set<string>();
    for (const r of repos) set.add(r.march);
    return Array.from(set).sort();
  }, [repos]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return repos.filter(r => {
      if (archFilter !== 'ALL' && r.march !== archFilter) return false;
      if (q && !r.repo_name.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [repos, search, archFilter]);

  const initialLoading = loading && repos.length === 0;

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        description="Custom package repositories registered for the build system."
        title="Repos"
      />

      <FilterToolbar>
        <div className="relative w-full max-w-sm">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="h-8 pl-8"
            onChange={e => setSearch(e.target.value)}
            placeholder="Search repos…"
            value={search}
          />
        </div>
        <div className="ml-auto flex items-center gap-2">
          <Select onValueChange={setArchFilter} value={archFilter}>
            <SelectTrigger className="h-8 w-[160px]">
              <SelectValue placeholder="Architecture" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="ALL">All architectures</SelectItem>
              {archOptions.map(a => (
                <SelectItem key={a} value={a}>
                  {a}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </FilterToolbar>

      {initialLoading ? (
        <Loader animate text="Loading repos…" />
      ) : filtered.length === 0 ? (
        <EmptyState
          description={
            repos.length === 0
              ? 'No custom repositories have been configured yet.'
              : 'No repos match the current filters.'
          }
          icon={<GitBranch />}
          title={repos.length === 0 ? 'No repos' : 'No matches'}
        />
      ) : (
        <ul className="flex flex-col divide-y rounded-lg border">
          {filtered.map(repo => (
            <li key={repo.id}>
              <Link
                className="flex items-center justify-between gap-4 px-4 py-3 transition-colors hover:bg-muted/50"
                href={`/dashboard/custom/repos/${repo.id}`}
              >
                <div className="flex min-w-0 flex-col gap-0.5">
                  <span className="truncate text-sm font-medium">
                    {repo.repo_name}
                  </span>
                  <MetadataRow
                    items={[
                      {value: repo.march},
                      {label: 'id', mono: true, value: repo.id},
                    ]}
                  />
                </div>
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
    </div>
  );
}
