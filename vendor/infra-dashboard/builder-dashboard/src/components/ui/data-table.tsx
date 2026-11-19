'use client';

import {
  ColumnDef,
  ColumnFiltersState,
  flexRender,
  getCoreRowModel,
  getExpandedRowModel,
  getFilteredRowModel,
  getPaginationRowModel,
  getSortedRowModel,
  RowSelectionState,
  SortingState,
  Table as TableType,
  useReactTable,
  VisibilityState,
} from '@tanstack/react-table';
import {LucideIcon} from 'lucide-react';
import * as React from 'react';

import {DataTablePagination} from '@/components/ui/data-table-pagination';
import {DataTableViewOptions} from '@/components/ui/data-table-view-options';
import {Input} from '@/components/ui/input';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {useGenericShortcutListener} from '@/hooks/use-keyboard-shortcut-listener';

interface DataTableProps<TData, TValue> {
  allowColumnToggle?: boolean;
  columns: ColumnDef<TData, TValue>[];
  customFilters?: ((table: TableType<TData>) => React.ReactNode)[];
  data: TData[];
  filters?: {
    icon?: LucideIcon;
    id: string;
    isPrimary?: boolean;
    placeholder?: string;
  }[];
  fullWidth?: boolean;
  getRowId?: (row: TData) => string;
  getSubRows?: (row: TData) => TData[];
  initialSortingState?: SortingState;
  itemCount?: number;
  manualFiltering?: boolean;
  manualPagination?: boolean;
  onPageChange?: (pageIndex: number) => void;
  onPageSizeChange?: (pageSize: number) => void;
  pageCount?: number;
  resetSelection?: boolean;
  shrinkFirstColumn?: boolean;
  viewOptionsAdditionalItems?: React.ReactNode;
}

export function DataTable<TData, TValue>({
  allowColumnToggle = true,
  columns,
  customFilters,
  data,
  filters,
  fullWidth = false,
  getRowId,
  getSubRows,
  initialSortingState = [],
  itemCount: packageCount,
  manualFiltering = false,
  manualPagination = false,
  onPageChange,
  onPageSizeChange,
  pageCount,
  resetSelection = false,
  shrinkFirstColumn = false,
  viewOptionsAdditionalItems = null,
}: Readonly<DataTableProps<TData, TValue>>) {
  const [sorting, setSorting] =
    React.useState<SortingState>(initialSortingState);
  const [columnFilters, setColumnFilters] = React.useState<ColumnFiltersState>(
    []
  );
  const [columnVisibility, setColumnVisibility] =
    React.useState<VisibilityState>({
      ID: false,
    });
  const [rowSelection, setRowSelection] = React.useState<RowSelectionState>({});
  React.useEffect(() => {
    setRowSelection({});
  }, [resetSelection]);
  const primarySearchFilterInputRef = React.useRef<HTMLInputElement>(null);
  // eslint-disable-next-line react-hooks/incompatible-library
  const table = useReactTable({
    columns,
    data,
    getCoreRowModel: getCoreRowModel(),
    getExpandedRowModel: getExpandedRowModel(),
    getFilteredRowModel: manualFiltering ? undefined : getFilteredRowModel(),
    getPaginationRowModel: manualPagination
      ? undefined
      : getPaginationRowModel(),
    getRowId,
    getSortedRowModel: getSortedRowModel(),
    getSubRows,
    initialState: {
      pagination: {
        pageSize: 20,
      },
    },
    manualFiltering,
    manualPagination,
    onColumnFiltersChange: setColumnFilters,
    onColumnVisibilityChange: setColumnVisibility,
    onRowSelectionChange: setRowSelection,
    onSortingChange: setSorting,
    pageCount,
    rowCount: packageCount ?? undefined,
    state: {
      columnFilters,
      columnVisibility,
      rowSelection,
      sorting,
    },
  });

  const primarySearchFilterShortcutCallback = React.useCallback(() => {
    if (primarySearchFilterInputRef.current) {
      primarySearchFilterInputRef.current.focus();
    }
  }, []);

  useGenericShortcutListener('/', primarySearchFilterShortcutCallback, true);

  return (
    <div
      className={
        fullWidth
          ? 'flex flex-col gap-y-4 w-full'
          : 'flex flex-col gap-y-4 max-w-7xl w-full mt-4'
      }
    >
      <div className="flex w-full flex-col lg:flex-row items-center gap-2">
        {filters?.map(x => (
          <Input
            className="max-w-xs"
            icon={x.icon}
            key={x.id}
            onChange={event =>
              table.getColumn(x.id)?.setFilterValue(event.target.value)
            }
            placeholder={x.placeholder}
            value={(table.getColumn(x.id)?.getFilterValue() as string) ?? ''}
            {...(x.isPrimary
              ? {
                  ref: primarySearchFilterInputRef,
                }
              : {})}
          />
        ))}
        {customFilters && (
          <div className="flex flex-wrap lg:flex-nowrap grow md:flex-row gap-2">
            {customFilters?.map(filter => filter(table))}
          </div>
        )}
        {viewOptionsAdditionalItems}
        {allowColumnToggle && (
          <div className="flex w-full lg:w-fit lg:ml-auto gap-2">
            <DataTableViewOptions table={table} />
          </div>
        )}
      </div>
      <div className="rounded-md border">
        <Table className="**:data-[slot=table-head]:first:pl-4">
          <TableHeader>
            {table.getHeaderGroups().map(headerGroup => (
              <TableRow key={headerGroup.id}>
                {headerGroup.headers.map(header => {
                  return (
                    <TableHead colSpan={header.colSpan} key={header.id}>
                      {header.isPlaceholder
                        ? null
                        : flexRender(
                            header.column.columnDef.header,
                            header.getContext()
                          )}
                    </TableHead>
                  );
                })}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody
            className={
              shrinkFirstColumn
                ? '**:data-[slot=table-cell]:first:w-9 **:data-[slot=table-cell]:first:pl-4'
                : '**:data-[slot=table-cell]:first:pl-4'
            }
          >
            {table.getRowModel().rows?.length ? (
              table.getRowModel().rows.map(row => (
                <TableRow
                  data-state={row.getIsSelected() && 'selected'}
                  key={row.id}
                >
                  {row.getVisibleCells().map(cell => (
                    <TableCell key={cell.id}>
                      {flexRender(
                        cell.column.columnDef.cell,
                        cell.getContext()
                      )}
                    </TableCell>
                  ))}
                </TableRow>
              ))
            ) : (
              <TableRow>
                <TableCell
                  className="h-24 text-center"
                  colSpan={columns.length}
                >
                  No data yet...
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
      <DataTablePagination
        onPageChange={onPageChange}
        onPageSizeChange={onPageSizeChange}
        table={table}
      />
    </div>
  );
}
