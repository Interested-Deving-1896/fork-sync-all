import {Table} from '@tanstack/react-table';
import {
  ChevronLeft,
  ChevronRight,
  ChevronsLeft,
  ChevronsRight,
} from 'lucide-react';

import {Button} from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';

interface DataTablePaginationProps<TData> {
  onPageChange?: (pageIndex: number) => void;
  onPageSizeChange?: (pageSize: number) => void;
  table: Table<TData>;
}

export function DataTablePagination<TData>({
  onPageChange,
  onPageSizeChange,
  table,
}: Readonly<DataTablePaginationProps<TData>>) {
  return (
    <div className="flex flex-wrap gap-y-2 items-center justify-between px-2">
      <div className="flex-1 text-sm text-muted-foreground">
        Showing{' '}
        {table.getState().pagination.pageIndex + 1 === table.getPageCount()
          ? table.getRowCount()
          : (table.getState().pagination.pageIndex + 1) *
            table.getState().pagination.pageSize}{' '}
        of {table.getRowCount()} row(s) (
        {Object.keys(table.getState().rowSelection).length} Selected).
      </div>
      <div className="flex md:flex-row flex-col items-center space-x-6 lg:space-x-8">
        <div className="flex items-center space-x-2">
          <p className="text-sm font-medium">Rows per page</p>
          <Select
            onValueChange={value => {
              onPageSizeChange?.(Number(value));
              table.setPageSize(Number(value));
            }}
            value={`${table.getState().pagination.pageSize}`}
          >
            <SelectTrigger className="h-8 w-[70px]">
              <SelectValue placeholder={table.getState().pagination.pageSize} />
            </SelectTrigger>
            <SelectContent side="top">
              {[10, 20, 30, 40, 50].map(pageSize => (
                <SelectItem key={pageSize} value={`${pageSize}`}>
                  {pageSize}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex w-28 items-center justify-center text-sm font-medium">
          Page {table.getState().pagination.pageIndex + 1} of{' '}
          {table.getPageCount()}
        </div>
        <div className="flex items-center space-x-2">
          <Button
            className="hidden h-8 w-8 p-0 lg:flex"
            disabled={!table.getCanPreviousPage()}
            onClick={() => {
              table.setPageIndex(0);
              onPageChange?.(0);
            }}
            variant="outline"
          >
            <span className="sr-only">Go to first page</span>
            <ChevronsLeft />
          </Button>
          <Button
            className="h-8 w-8 p-0"
            disabled={!table.getCanPreviousPage()}
            onClick={() => {
              onPageChange?.(table.getState().pagination.pageIndex - 1);
              table.previousPage();
            }}
            variant="outline"
          >
            <span className="sr-only">Go to previous page</span>
            <ChevronLeft />
          </Button>
          <Button
            className="h-8 w-8 p-0"
            disabled={!table.getCanNextPage()}
            onClick={() => {
              onPageChange?.(table.getState().pagination.pageIndex + 1);
              table.nextPage();
            }}
            variant="outline"
          >
            <span className="sr-only">Go to next page</span>
            <ChevronRight />
          </Button>
          <Button
            className="hidden h-8 w-8 p-0 lg:flex"
            disabled={!table.getCanNextPage()}
            onClick={() => {
              onPageChange?.(table.getPageCount() - 1);
              table.setPageIndex(table.getPageCount() - 1);
            }}
            variant="outline"
          >
            <span className="sr-only">Go to last page</span>
            <ChevronsRight />
          </Button>
        </div>
      </div>
    </div>
  );
}
