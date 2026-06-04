'use client';

import {ColumnDef, Table} from '@tanstack/react-table';
import {Ellipsis, Logs, RotateCcw, Search, SquareTerminal} from 'lucide-react';
import Link from 'next/link';
import {useCallback, useEffect, useMemo, useState} from 'react';
import {toast} from 'sonner';

import {listRebuildPackages, rebuildPackage} from '@/app/actions/packages';
import Loader from '@/components/loader';
import {RebuildPackagesDialog} from '@/components/rebuild-packages-dialog';
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
import {useSidebar} from '@/components/ui/sidebar';
import {
  BasePackageWithIDList,
  PackageMArch,
  packageMArchValues,
  PackageRepo,
  packageRepoValues,
  PackageStatus,
  packageStatusValues,
  RebuildPackage,
  RebuildPackageList,
  UserScope,
} from '@/lib/typings';
import {checkScopes, packageStatusToIcon} from '@/lib/utils';

export default function RebuildQueuePackageListPage() {
  const {activeServer, scopes} = useSidebar();
  const [data, setData] = useState<null | RebuildPackageList>(null);
  const [error, setError] = useState<null | string>(null);
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

  const enableRebuild = useMemo(
    () => checkScopes(scopes, [UserScope.READ, UserScope.WRITE]),
    [scopes]
  );
  const columns: ColumnDef<RebuildPackage>[] = useMemo(
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
                  for (const row of table.getRowModel().rows) {
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
        accessorKey: 'pkgbase',
        cell: ({row}) => (
          <span className="font-medium">{row.original.pkgbase}</span>
        ),
        filterFn: 'includesString',
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Pkgbase" />
        ),
        id: 'pkgbase',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">{row.original.repository}</span>
        ),
        filterFn: (row, _, filterValue) => {
          if (Array.isArray(filterValue) && filterValue.length) {
            return filterValue.includes(row.original.repository);
          }
          return true;
        },
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Repository" />
        ),
        id: 'repository',
      },
      {
        cell: ({row}) => (
          <span className="font-medium">{row.original.march}</span>
        ),
        filterFn: (row, _, filterValue) => {
          if (Array.isArray(filterValue) && filterValue.length) {
            return filterValue.includes(row.original.march);
          }
          return true;
        },
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Arch" />
        ),
        id: 'arch',
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
        filterFn: (row, _, filterValue) => {
          if (Array.isArray(filterValue) && filterValue.length) {
            return filterValue.includes(row.original.status);
          }
          return true;
        },
        header: ({column}) => (
          <DataTableColumnHeader column={column} title="Status" />
        ),
        id: 'status',
      },
      {
        accessorKey: 'updated',
        cell: ({row}) => {
          const date = new Date(row.original.updated);
          return (
            <span className="font-medium">
              {date.toLocaleDateString()}, {date.toLocaleTimeString()}
            </span>
          );
        },
        enableSorting: true,
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

  useEffect(() => {
    setError(null);
    setData(null);
    listRebuildPackages()
      .then(response => {
        if ('error' in response && response.error) {
          setError(response.error);
          toast.error(`Failed to fetch package list: ${response.error}`, {
            closeButton: true,
            duration: Infinity,
          });
        } else if (Array.isArray(response)) {
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
  }, [activeServer]);

  const customFilters = useMemo(
    () => [
      (table: Table<RebuildPackage>) => (
        <div className="flex" key="march-filter">
          <ComboBox
            items={packageMArchValues}
            onItemsUpdate={marches =>
              table.getColumn('arch')?.setFilterValue(marches)
            }
            searchNoResultsText="No architectures found"
            searchPlaceholder="Search architectures..."
            selectedItems={
              (table.getColumn('arch')?.getFilterValue() ??
                []) as PackageMArch[]
            }
            title="Architecture"
          />
        </div>
      ),
      (table: Table<RebuildPackage>) => (
        <div className="flex" key="repo-filter">
          <ComboBox
            items={packageRepoValues}
            onItemsUpdate={repos =>
              table.getColumn('repository')?.setFilterValue(repos)
            }
            searchNoResultsText="No repositories found"
            searchPlaceholder="Search repositories..."
            selectedItems={
              (table.getColumn('repository')?.getFilterValue() ??
                []) as PackageRepo[]
            }
            title="Repository"
          />
        </div>
      ),
      (table: Table<RebuildPackage>) => (
        <div className="flex" key="status-filter">
          <ComboBox
            items={packageStatusValues}
            onItemsUpdate={statuses =>
              table.getColumn('status')?.setFilterValue(statuses)
            }
            searchNoResultsText="No statuses found"
            searchPlaceholder="Search statuses..."
            selectedItems={
              (table.getColumn('status')?.getFilterValue() ??
                []) as PackageStatus[]
            }
            title="Status"
          />
        </div>
      ),
    ],
    []
  );
  const filters = useMemo(
    () => [
      {
        icon: Search,
        id: 'pkgbase',
        isPrimary: true,
        placeholder: 'Search packages...',
      },
    ],
    []
  );
  const initialSortingState = useMemo(
    () => [
      {
        desc: true,
        id: 'updated at',
      },
    ],
    []
  );

  return (
    <Card className="flex h-full w-full items-center p-2">
      <RebuildPackagesDialog
        onOpenChange={onOpenChange}
        open={showRebuildModal}
        packages={rebuildPackages}
      />
      {data ? (
        <DataTable
          columns={columns}
          customFilters={customFilters}
          data={data}
          filters={filters}
          getRowId={row =>
            `${row.pkgbase}-${row.pkgbase}-${row.repository}-${row.march}`
          }
          initialSortingState={initialSortingState}
          resetSelection={selectionReset}
          shrinkFirstColumn
          viewOptionsAdditionalItems={
            rebuildPackages.length ? (
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
            ) : null
          }
        />
      ) : (
        <Loader animate text={error ?? 'Loading package list...'} />
      )}
    </Card>
  );
}
