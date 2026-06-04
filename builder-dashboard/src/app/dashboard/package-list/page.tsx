'use client';

import {ColumnDef} from '@tanstack/react-table';
import {Ellipsis, Logs, RotateCcw, Search, SquareTerminal} from 'lucide-react';
import Link from 'next/link';
import {
  Fragment,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {toast} from 'sonner';
import {useDebounce} from 'use-debounce';

import {
  listPackages,
  rebuildPackage,
  searchPackages,
} from '@/app/actions/packages';
import Loader from '@/components/loader';
import {RebuildPackagesDialog} from '@/components/rebuild-packages-dialog';
import {StatsKPI} from '@/components/stats-kpi';
import {Badge} from '@/components/ui/badge';
import {Button} from '@/components/ui/button';
import {Card} from '@/components/ui/card';
import {Checkbox} from '@/components/ui/checkbox';
import {ComboBox} from '@/components/ui/combobox';
import {DataTable} from '@/components/ui/data-table';
import {DataTableColumnHeader} from '@/components/ui/data-table-column-header';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {Input} from '@/components/ui/input';
import {useSidebar} from '@/components/ui/sidebar';
import {useGenericShortcutListener} from '@/hooks/use-keyboard-shortcut-listener';
import {
  BasePackageWithIDList,
  ListPackageResponse,
  Package,
  PackageMArch,
  packageMArchValues,
  PackageRepo,
  packageRepoValues,
  PackageStatus,
  packageStatusValues,
  UserScope,
} from '@/lib/typings';
import {checkScopes, packageStatusToIcon} from '@/lib/utils';

export default function PackageListPage() {
  const {activeServer, scopes} = useSidebar();
  const [data, setData] = useState<ListPackageResponse | null>(null);
  const [error, setError] = useState<null | string>(null);
  const [pageSize, setPageSize] = useState(20);
  const [currentPage, setCurrentPage] = useState(1);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearchQuery] = useDebounce(searchQuery, 800);
  const [manual, setManual] = useState(true);
  const [marchFilter, setMarchFilter] = useState<PackageMArch[]>([]);
  const [repoFilter, setRepoFilter] = useState<PackageRepo[]>([]);
  const [statusFilter, setStatusFilter] = useState<PackageStatus[]>([]);
  const [rebuildPackages, setRebuildPackages] = useState<BasePackageWithIDList>(
    []
  );
  const [showRebuildModal, setShowRebuildModal] = useState(false);
  const [selectionReset, setSelectionReset] = useState(false);
  const onOpenChange = useCallback((state: boolean) => {
    if (!state) {
      setRebuildPackages([]);
      setSelectionReset(old => !old);
    }
    setShowRebuildModal(state);
  }, []);
  const primarySearchFilterInputRef = useRef<HTMLInputElement>(null);
  const primarySearchFilterShortcutCallback = useCallback(() => {
    if (primarySearchFilterInputRef.current) {
      primarySearchFilterInputRef.current.focus();
    }
  }, []);

  useGenericShortcutListener('/', primarySearchFilterShortcutCallback, true);

  const enableRebuild = useMemo(
    () => checkScopes(scopes, [UserScope.READ, UserScope.WRITE]),
    [scopes]
  );
  const columns: ColumnDef<Package>[] = useMemo(
    () => [
      {
        cell: ({row}) => (
          <Checkbox
            aria-label="Select row"
            checked={row.getIsSelected()}
            className="mb-2"
            onCheckedChange={value => {
              row.toggleSelected(!!value);
              if (value === true) {
                setRebuildPackages(old => [
                  ...old,
                  {
                    id: row.id,
                    march: row.original.march,
                    pkgbase: row.original.pkgbase,
                    repository: row.original.repository,
                  },
                ]);
              } else if (value === false) {
                setRebuildPackages(old => old.filter(pkg => pkg.id !== row.id));
              }
            }}
          />
        ),
        enableHiding: false,
        enableSorting: false,
        header: ({table}) => (
          <Checkbox
            aria-label="Select all"
            checked={
              table.getIsAllPageRowsSelected() ||
              (table.getIsSomePageRowsSelected() && 'indeterminate')
            }
            className="mb-2"
            onCheckedChange={value => {
              table.toggleAllPageRowsSelected(!!value);
              if (value === true) {
                setRebuildPackages(old => {
                  const newPkgs: BasePackageWithIDList = [];
                  for (const row of table.getCoreRowModel().rows) {
                    if (!old.some(pkg => pkg.id === row.id)) {
                      newPkgs.push({
                        id: row.id,
                        march: row.original.march,
                        pkgbase: row.original.pkgbase,
                        repository: row.original.repository,
                      });
                    }
                  }
                  return [...old, ...newPkgs];
                });
              } else if (value === false) {
                const removePkgs = new Set(
                  table.getSelectedRowModel().rows.map(row => row.id)
                );
                setRebuildPackages(old =>
                  old.filter(pkg => !removePkgs.has(pkg.id))
                );
              }
            }}
          />
        ),
        id: 'select',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">
            {row.original.pkgname} ({row.original.pkgbase})
          </span>
        ),
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Name" />
        ),
        id: 'name',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">{row.original.repository}</span>
        ),
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Repository" />
        ),
        id: 'repository',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">{row.original.march}</span>
        ),
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Arch" />
        ),
        id: 'arch',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">{row.original.version}</span>
        ),
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Version" />
        ),
        id: 'version',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">{row.original.repo_version}</span>
        ),
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Repo Version" />
        ),
        id: 'repo version',
      },
      {
        cell: ({row}) => (
          <div className="w-32">
            <Badge className="text-muted-foreground px-1.5" variant="outline">
              {packageStatusToIcon(row.original.status)}
              {row.original.status}
            </Badge>
          </div>
        ),
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Status" />
        ),
        id: 'status',
      },
      {
        cell: ({row}) => {
          const date = new Date(row.original.updated * 1000);
          return (
            <span className="font-medium">
              {date.toLocaleDateString()}, {date.toLocaleTimeString()}
            </span>
          );
        },
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Updated At" />
        ),
        id: 'updated at',
      },
      {
        cell: ({row}) => (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                className="data-[state=open]:bg-muted text-muted-foreground flex size-8"
                size="icon"
                variant="ghost"
              >
                <Ellipsis className="size-5" />
                <span className="sr-only">Open menu</span>
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="max-w-48">
              <DropdownMenuItem
                disabled={!enableRebuild}
                hidden={!enableRebuild}
                onSelect={() => {
                  if (!enableRebuild) {
                    return;
                  }
                  const toastId = toast.loading(
                    `Requesting rebuild for PkgBase: ${row.original.pkgbase} MArch: ${row.original.march} Repo: ${row.original.repository}...`
                  );
                  rebuildPackage(
                    row.original.pkgbase,
                    row.original.march,
                    row.original.repository
                  ).then(response => {
                    if ('error' in response && response.error) {
                      toast.error(
                        `Failed to rebuild package: ${response.error}`,
                        {
                          closeButton: true,
                          duration: Infinity,
                          id: toastId,
                        }
                      );
                    } else if ('track_id' in response && response.track_id) {
                      toast.success(
                        `Rebuild request for PkgBase: ${row.original.pkgbase} MArch: ${row.original.march} Repo: ${row.original.repository} has been queued with Track ID: ${response.track_id}.`,
                        {id: toastId}
                      );
                    }
                  });
                }}
                variant="destructive"
              >
                <RotateCcw /> Rebuild
              </DropdownMenuItem>
              <DropdownMenuSeparator hidden={!enableRebuild} />
              <DropdownMenuItem
                asChild
                disabled={row.original.status !== PackageStatus.FAILED}
              >
                <Link
                  className="flex items-center gap-2 w-full"
                  href={`/dashboard/logs/${row.original.march}/${row.original.pkgbase}`}
                  prefetch={false}
                >
                  <SquareTerminal /> Get Logs
                </Link>
              </DropdownMenuItem>
              <DropdownMenuItem
                asChild
                disabled={row.original.status !== PackageStatus.FAILED}
              >
                <Link
                  className="flex items-center gap-2 w-full"
                  href={`/dashboard/logs/${row.original.march}/${row.original.pkgbase}?raw=true`}
                  prefetch={false}
                >
                  <Logs /> Get Raw Logs
                </Link>
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        ),
        id: 'actions',
      },
    ],
    [enableRebuild]
  );

  const onMarchFilterUpdate = useCallback(
    (marches: PackageMArch[]) => setMarchFilter(marches),
    []
  );
  const onRepoFilterUpdate = useCallback(
    (repos: PackageRepo[]) => setRepoFilter(repos),
    []
  );
  const onStatusFilterUpdate = useCallback(
    (statuses: PackageStatus[]) => setStatusFilter(statuses),
    []
  );
  const statusFilterUpdate = useCallback(
    (status: PackageStatus) =>
      setStatusFilter(old => {
        if (old.includes(status)) {
          return old.filter(s => s !== status);
        }
        return [...old, status];
      }),
    []
  );

  useEffect(() => {
    setError(null);
    if (debouncedSearchQuery) {
      return;
    }
    listPackages({
      current_page: currentPage,
      march_filter: marchFilter,
      page_size: pageSize,
      repo_filter: repoFilter,
      status_filter: statusFilter,
    })
      .then(response => {
        if ('error' in response && response.error) {
          setError(response.error);
          toast.error(`Failed to fetch package list: ${response.error}`, {
            closeButton: true,
            duration: Infinity,
          });
        }
        if ('packages' in response) {
          setManual(true);
          setData(response);
        }
      })
      .catch(() => {
        setError('Failed to fetch package list, please try again later.');
        toast.error('Failed to fetch package list, please try again later.', {
          closeButton: true,
          duration: Infinity,
        });
      });
  }, [
    activeServer,
    currentPage,
    debouncedSearchQuery,
    marchFilter,
    pageSize,
    repoFilter,
    statusFilter,
  ]);

  useEffect(() => {
    setData(null);
    setError(null);
    setCurrentPage(1);
    setSearchQuery('');
    setMarchFilter([]);
    setRepoFilter([]);
    setStatusFilter([]);
    setRebuildPackages([]);
  }, [activeServer]);

  useEffect(() => {
    setError(null);
    if (debouncedSearchQuery) {
      searchPackages({
        march_filter: marchFilter,
        repo_filter: repoFilter,
        search: debouncedSearchQuery,
        status_filter: statusFilter,
      }).then(response => {
        if ('error' in response && response.error) {
          setError(response.error);
          toast.error(`Failed to search packages: ${response.error}`, {
            closeButton: true,
            duration: Infinity,
          });
        } else if (Array.isArray(response)) {
          setManual(false);
          setData({
            packages: response,
            total_items: response.length,
            total_pages: 1,
          });
        }
      });
    }
  }, [debouncedSearchQuery, marchFilter, repoFilter, statusFilter]);

  return (
    <Card className="flex flex-col h-full w-full items-center p-2">
      <StatsKPI statusFilterUpdate={statusFilterUpdate} />
      <RebuildPackagesDialog
        onOpenChange={onOpenChange}
        open={showRebuildModal}
        packages={rebuildPackages}
      />
      {data ? (
        <DataTable
          columns={columns}
          data={data.packages}
          getRowId={row =>
            `${row.pkgbase}-${row.pkgname}-${row.repository}-${row.march}`
          }
          itemCount={manual ? data.total_items : undefined}
          manualFiltering={manual}
          manualPagination={manual}
          onPageChange={pageIndex => setCurrentPage(pageIndex + 1)}
          onPageSizeChange={pageSize => {
            const currentEntryCutoff = Math.min(
              (currentPage - 1) * pageSize + 1,
              data.total_items
            );
            setCurrentPage(Math.floor(currentEntryCutoff / pageSize));
            setPageSize(pageSize);
          }}
          pageCount={manual ? data.total_pages : undefined}
          resetSelection={selectionReset}
          shrinkFirstColumn
          viewOptionsAdditionalItems={
            <Fragment>
              <div className="flex shrink w-full">
                <Input
                  className="max-w-xs w-full"
                  icon={Search}
                  id="package-search"
                  onChange={e => setSearchQuery(e.target.value)}
                  placeholder="Search packages..."
                  ref={primarySearchFilterInputRef}
                  type="text"
                  value={searchQuery}
                />
              </div>
              <div className="flex flex-wrap lg:flex-nowrap gap-2">
                {rebuildPackages.length ? (
                  <div className="flex">
                    <Button
                      className="h-8"
                      disabled={!enableRebuild}
                      onClick={() => setShowRebuildModal(true)}
                      size="sm"
                      variant="outline"
                    >
                      <RotateCcw />
                      Rebuild Selected Packages
                    </Button>
                  </div>
                ) : null}
                <div className="flex">
                  <ComboBox
                    items={packageMArchValues}
                    onItemsUpdate={onMarchFilterUpdate}
                    searchNoResultsText="No architectures found"
                    searchPlaceholder="Search architectures..."
                    selectedItems={marchFilter}
                    title="Architecture"
                  />
                </div>
                <div className="flex">
                  <ComboBox
                    items={packageRepoValues}
                    onItemsUpdate={onRepoFilterUpdate}
                    searchNoResultsText="No repositories found"
                    searchPlaceholder="Search repositories..."
                    selectedItems={repoFilter}
                    title="Repository"
                  />
                </div>
                <div className="flex">
                  <ComboBox
                    items={packageStatusValues}
                    onItemsUpdate={onStatusFilterUpdate}
                    searchNoResultsText="No statuses found"
                    searchPlaceholder="Search statuses..."
                    selectedItems={statusFilter}
                    title="Status"
                  />
                </div>
              </div>
            </Fragment>
          }
        />
      ) : (
        <Loader animate text={error ?? 'Loading package list...'} />
      )}
    </Card>
  );
}
