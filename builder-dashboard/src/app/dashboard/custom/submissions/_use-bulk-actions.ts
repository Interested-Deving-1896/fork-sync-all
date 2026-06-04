'use client';

import {useCallback, useState} from 'react';
import {toast} from 'sonner';

import {
  approveSubmission,
  cancelSubmission,
  queueSubmission,
  rejectSubmission,
} from '@/app/actions/custom';
import {isActionError, type PackageSubmission} from '@/lib/typings';

import {actionLabel, type BulkAction} from './_types';

interface BulkState {
  action: BulkAction | null;
  ids: string[];
  loading: boolean;
}

interface UseBulkActionsArgs {
  currentUser: string;
  isAdmin: boolean;
  onComplete: () => void;
  selected: Set<string>;
  submissions: PackageSubmission[];
}

export function useBulkSubmissionActions({
  currentUser,
  isAdmin,
  onComplete,
  selected,
  submissions,
}: UseBulkActionsArgs) {
  const [bulk, setBulk] = useState<BulkState>({
    action: null,
    ids: [],
    loading: false,
  });

  const open = useCallback(
    (action: BulkAction) => {
      // Cancel is allowed for admins, and otherwise restricted to the submitter
      // of each row (mirrors the per-submission detail-page gating).
      const ids =
        action === 'cancel' && !isAdmin
          ? Array.from(selected).filter(id => {
              const sub = submissions.find(s => s.id === id);
              return sub != null && sub.submitter === currentUser;
            })
          : Array.from(selected);
      if (ids.length === 0) {
        toast.error('No submissions you can cancel are selected.');
        return;
      }
      setBulk({action, ids, loading: false});
    },
    [selected, submissions, isAdmin, currentUser]
  );

  const close = useCallback(
    () => setBulk(prev => ({...prev, action: null})),
    []
  );

  const run = useCallback(
    async (note: string) => {
      if (!bulk.action) return;
      const action = bulk.action;
      const ids = bulk.ids;
      setBulk(prev => ({...prev, loading: true}));
      const trimmed = note.trim() || undefined;
      const toastId = toast.loading(
        `${actionLabel(action)} ${ids.length} submission(s)…`
      );
      try {
        const results = await Promise.all(
          ids.map(id => {
            switch (action) {
              case 'approve':
                return approveSubmission(id, trimmed);
              case 'cancel':
                return cancelSubmission(id);
              case 'queue':
                return queueSubmission(id);
              case 'reject':
                return rejectSubmission(id, trimmed);
            }
          })
        );
        const failed = results.filter(isActionError).length;
        if (failed > 0) {
          toast.error(`${failed} of ${results.length} action(s) failed`, {
            id: toastId,
          });
        } else {
          toast.success(
            `${actionLabel(action)} ${results.length} submission(s).`,
            {id: toastId}
          );
        }
        setBulk({action: null, ids: [], loading: false});
        onComplete();
      } catch {
        toast.error('An unexpected error occurred.', {id: toastId});
        setBulk(prev => ({...prev, loading: false}));
      }
    },
    [bulk.action, bulk.ids, onComplete]
  );

  return {
    action: bulk.action,
    close,
    ids: bulk.ids,
    loading: bulk.loading,
    open,
    run,
  };
}
