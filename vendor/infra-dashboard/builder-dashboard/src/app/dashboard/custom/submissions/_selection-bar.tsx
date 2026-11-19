'use client';

import {X} from 'lucide-react';

import {Button} from '@/components/ui/button';
import {FilterToolbar} from '@/components/ui/filter-toolbar';

import type {BulkAction} from './_types';

interface SubmissionSelectionBarProps {
  count: number;
  isAdmin: boolean;
  onAction: (action: BulkAction) => void;
  onClear: () => void;
}

export function SubmissionSelectionBar({
  count,
  isAdmin,
  onAction,
  onClear,
}: SubmissionSelectionBarProps) {
  return (
    <FilterToolbar selection>
      <div className="flex w-full flex-wrap items-center gap-2">
        <span className="text-sm font-medium">{count} selected</span>
        <div className="ml-auto flex flex-wrap items-center gap-2">
          {isAdmin && (
            <>
              <Button
                onClick={() => onAction('approve')}
                size="sm"
                variant="brand"
              >
                Approve
              </Button>
              <Button
                onClick={() => onAction('reject')}
                size="sm"
                variant="destructive"
              >
                Reject
              </Button>
              <Button
                onClick={() => onAction('queue')}
                size="sm"
                variant="outline"
              >
                Queue
              </Button>
            </>
          )}
          <Button
            onClick={() => onAction('cancel')}
            size="sm"
            variant="outline"
          >
            Cancel
          </Button>
          <Button onClick={onClear} size="icon" variant="ghost">
            <X className="size-4" />
            <span className="sr-only">Clear selection</span>
          </Button>
        </div>
      </div>
    </FilterToolbar>
  );
}
