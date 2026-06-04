'use client';

import {Package as PackageIcon, Search, UserPlus} from 'lucide-react';
import {useCallback, useEffect, useMemo, useState} from 'react';

import {getCustomPackages, getCustomRepos} from '@/app/actions/custom';
import {AddMaintainerDialog} from '@/components/custom/add-maintainer-dialog';
import {
  pulseFor,
  toneFor,
  variantFor,
} from '@/components/custom/package-status';
import Loader from '@/components/loader';
import {Badge} from '@/components/ui/badge';
import {Button} from '@/components/ui/button';
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
import {useSidebar} from '@/components/ui/sidebar';
import {StatusDot} from '@/components/ui/status-dot';
import {useInfiniteList} from '@/lib/hooks/use-infinite-list';
import {
  type CustomPackage,
  type CustomRepo,
  isActionError,
  unwrapOr,
  UserScope,
} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

export default function PackagesListPage() {
  const {scopes, username: currentUser} = useSidebar();
  const isAdmin = useMemo(
    () => checkScopes(scopes, [UserScope.ADMIN]),
    [scopes]
  );

  const [repos, setRepos] = useState<CustomRepo[]>([]);
  const [filters, setFilters] = useState({
    archFilter: 'ALL',
    search: '',
    statusFilter: 'ALL',
  });
  const [dialog, setDialog] = useState<{
    open: boolean;
    selected: CustomPackage | null;
  }>({open: false, selected: null});

  const {archFilter, search, statusFilter} = filters;
  const {open: dialogOpen, selected} = dialog;

  const fetchPage = useCallback(async (page: number, size: number) => {
    const r = await getCustomPackages(page, size);
    if (isActionError(r)) return r;
    return {items: r.custom_packages, totalPages: r.total_pages};
  }, []);

  const {
    hasMore,
    items: packages,
    loading,
    reload,
    sentinelRef,
  } = useInfiniteList<CustomPackage>(fetchPage);

  useEffect(() => {
    getCustomRepos().then(rs => {
      setRepos(unwrapOr(rs, {repos: [], total_items: 0, total_pages: 0}).repos);
    });
  }, []);

  const archOptions = useMemo(() => {
    const s = new Set<string>();
    for (const p of packages) s.add(p.march);
    return Array.from(s).sort();
  }, [packages]);

  const statusOptions = useMemo(() => {
    const s = new Set<string>();
    for (const p of packages) s.add(p.status);
    return Array.from(s).sort();
  }, [packages]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return packages.filter(p => {
      if (archFilter !== 'ALL' && p.march !== archFilter) return false;
      if (statusFilter !== 'ALL' && p.status !== statusFilter) return false;
      if (q) {
        const hay = `${p.pkgbase} ${p.pkgname}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [packages, search, archFilter, statusFilter]);

  const initialLoading = loading && packages.length === 0;

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        description="Custom packages currently tracked by the build system."
        title="Packages"
      />

      <FilterToolbar>
        <div className="relative w-full max-w-sm">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="h-8 pl-8"
            onChange={e =>
              setFilters(prev => ({...prev, search: e.target.value}))
            }
            placeholder="Search packages…"
            value={search}
          />
        </div>
        <div className="ml-auto flex items-center gap-2">
          <Select
            onValueChange={v =>
              setFilters(prev => ({...prev, statusFilter: v}))
            }
            value={statusFilter}
          >
            <SelectTrigger className="h-8 w-[140px]">
              <SelectValue placeholder="Status" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="ALL">All statuses</SelectItem>
              {statusOptions.map(s => (
                <SelectItem key={s} value={s}>
                  {s}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <Select
            onValueChange={v => setFilters(prev => ({...prev, archFilter: v}))}
            value={archFilter}
          >
            <SelectTrigger className="h-8 w-[140px]">
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
        <Loader animate text="Loading packages…" />
      ) : filtered.length === 0 ? (
        <EmptyState
          description={
            packages.length === 0
              ? 'No custom packages have been built yet.'
              : 'No packages match the current filters.'
          }
          icon={<PackageIcon />}
          title={packages.length === 0 ? 'No packages' : 'No matches'}
        />
      ) : (
        <ul className="flex flex-col divide-y rounded-lg border">
          {filtered.map(pkg => (
            <li
              className="group flex items-center gap-4 px-4 py-3 transition-colors hover:bg-muted/50"
              key={`${pkg.repository}-${pkg.march}-${pkg.pkgname}`}
            >
              <StatusDot
                pulse={pulseFor(pkg.status)}
                tone={toneFor(pkg.status)}
              />
              <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                <span className="truncate text-sm font-medium">
                  {pkg.pkgbase}
                </span>
                <MetadataRow
                  items={[
                    {value: pkg.pkgname},
                    {value: pkg.repository},
                    {value: pkg.march},
                    {label: 'v', mono: true, value: pkg.version},
                    {
                      value: new Date(pkg.updated * 1000).toLocaleString(),
                    },
                  ]}
                />
              </div>
              <Badge variant={variantFor(pkg.status)}>{pkg.status}</Badge>
              {isAdmin && (
                <Button
                  className="opacity-0 transition-opacity group-hover:opacity-100"
                  onClick={() => setDialog({open: true, selected: pkg})}
                  size="xs"
                  variant="outline"
                >
                  <UserPlus className="size-3.5" />
                  Maintainer
                </Button>
              )}
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
        key={selected ? `${selected.pkgbase}|${selected.repository}` : 'add'}
        onOpenChange={open =>
          setDialog(prev => ({
            open,
            selected: open ? prev.selected : null,
          }))
        }
        onSuccess={reload}
        open={dialogOpen}
        packages={selected ? [selected] : packages}
        prefill={
          selected
            ? {
                pkgbase: selected.pkgbase,
                repoId: repos.find(
                  r =>
                    r.repo_name === selected.repository &&
                    r.march === selected.march
                )?.id,
              }
            : undefined
        }
        repos={repos}
      />
    </div>
  );
}
