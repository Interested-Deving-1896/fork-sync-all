'use client';

import {useEffect, useState} from 'react';

import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {Label} from '@/components/ui/label';
import {Textarea} from '@/components/ui/textarea';

import {actionLabel, type BulkAction} from './_types';

interface BulkActionDialogProps {
  action: BulkAction | null;
  count: number;
  loading: boolean;
  onConfirm: (note: string) => void;
  onOpenChange: (open: boolean) => void;
}

export function BulkActionDialog({
  action,
  count,
  loading,
  onConfirm,
  onOpenChange,
}: BulkActionDialogProps) {
  const open = action !== null;
  const [note, setNote] = useState('');

  useEffect(() => {
    if (open) setNote('');
  }, [open]);

  const showNote = action === 'approve' || action === 'reject';
  const destructive = action === 'reject' || action === 'cancel';

  return (
    <Dialog onOpenChange={onOpenChange} open={open}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>
            {action ? actionLabel(action) : ''} {count} submission(s)
          </DialogTitle>
        </DialogHeader>
        {showNote && (
          <div className="flex flex-col gap-2 py-2">
            <Label htmlFor="bulk-note">Note (optional)</Label>
            <Textarea
              id="bulk-note"
              onChange={e => setNote(e.target.value)}
              placeholder="Applied to every selected submission"
              value={note}
            />
          </div>
        )}
        <DialogFooter>
          <DialogClose asChild>
            <Button disabled={loading} variant="outline">
              Cancel
            </Button>
          </DialogClose>
          <Button
            disabled={loading}
            onClick={() => onConfirm(note)}
            variant={destructive ? 'destructive' : 'brand'}
          >
            {action ? actionLabel(action) : 'Confirm'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
