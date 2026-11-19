'use client';

import {ColumnDef} from '@tanstack/react-table';
import {toast} from 'sonner';

import {bulkRebuildPackages} from '@/app/actions/packages';
import {Button} from '@/components/ui/button';
import {DataTable} from '@/components/ui/data-table';
import {DataTableColumnHeader} from '@/components/ui/data-table-column-header';
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {BasePackageWithID, BasePackageWithIDList} from '@/lib/typings';

const columns: ColumnDef<BasePackageWithID>[] = [
  {
    cell: ({row}) => (
      <span className="font-medium">{row.original.pkgbase}</span>
    ),
    header: ({column}) => (
      <DataTableColumnHeader column={column} title="PkgBase" />
    ),
    id: 'pkgbase',
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
    cell: ({row}) => <span className="font-medium">{row.original.march}</span>,
    header: ({column}) => (
      <DataTableColumnHeader column={column} title="Arch" />
    ),
    id: 'arch',
  },
];

export function RebuildPackagesDialog({
  onOpenChange,
  open,
  packages,
}: Readonly<{
  onOpenChange: (state: boolean) => void;
  open: boolean;
  packages: BasePackageWithIDList;
}>) {
  return (
    <Dialog modal onOpenChange={onOpenChange} open={open}>
      <DialogContent className="max-w-3xl w-full">
        <DialogHeader>
          <DialogTitle className="text-center">Rebuild Packages</DialogTitle>
          <DialogDescription>
            You are about to rebuild the following packages ({packages.length}):
          </DialogDescription>
        </DialogHeader>
        <div className="max-h-96 overflow-y-auto">
          <DataTable
            allowColumnToggle={false}
            columns={columns}
            data={packages}
            fullWidth
          />
        </div>
        <DialogFooter>
          <DialogClose asChild>
            <Button variant="outline">Cancel</Button>
          </DialogClose>
          <Button
            onClick={() => {
              const toastId = toast.loading(
                `Queueing bulk rebuild for ${packages.length} packages...`
              );
              bulkRebuildPackages(packages).then(response => {
                if ('error' in response) {
                  toast.error(response.error, {
                    closeButton: true,
                    duration: Infinity,
                    id: toastId,
                  });
                } else {
                  toast.success(
                    `Successfully queued bulk rebuild for ${response.length} packages.`,
                    {
                      duration: 5000,
                      id: toastId,
                    }
                  );
                }
                onOpenChange(false);
              });
            }}
          >
            Rebuild
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
