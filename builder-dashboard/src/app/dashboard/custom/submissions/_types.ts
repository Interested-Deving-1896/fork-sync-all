import type {SavedView} from '@/lib/saved-views';

import {SubmissionStatus} from '@/lib/typings';

export type BulkAction = 'approve' | 'cancel' | 'queue' | 'reject';

export interface SubmissionFilters {
  arch: string;
  recentOnly: boolean;
  repo: string;
  search: string;
  status: string;
}

export const DEFAULT_FILTERS: SubmissionFilters = {
  arch: 'ALL',
  recentOnly: false,
  repo: 'ALL',
  search: '',
  status: 'ALL',
};

export const BUILTIN_VIEWS: SavedView<SubmissionFilters>[] = [
  {
    builtin: true,
    filters: {...DEFAULT_FILTERS, status: SubmissionStatus.PENDING_REVIEW},
    id: 'builtin:pending-reviews',
    name: 'Pending reviews',
  },
  {
    builtin: true,
    filters: {
      ...DEFAULT_FILTERS,
      recentOnly: true,
      status: SubmissionStatus.BUILD_FAILED,
    },
    id: 'builtin:failed-today',
    name: 'Failed today',
  },
];

export type SubmissionBadgeVariant =
  | 'building'
  | 'danger'
  | 'info'
  | 'muted'
  | 'success'
  | 'warning';

export function actionLabel(a: BulkAction): string {
  switch (a) {
    case 'approve':
      return 'Approve';
    case 'cancel':
      return 'Cancel';
    case 'queue':
      return 'Queue build';
    case 'reject':
      return 'Reject';
  }
}

export function badgeVariantFor(
  status: string | SubmissionStatus
): SubmissionBadgeVariant {
  switch (status) {
    case SubmissionStatus.APPROVED:
      return 'info';
    case SubmissionStatus.BUILD_DONE:
      return 'success';
    case SubmissionStatus.BUILD_FAILED:
    case SubmissionStatus.REJECTED:
      return 'danger';
    case SubmissionStatus.BUILD_QUEUED:
      return 'building';
    case SubmissionStatus.PENDING_REVIEW:
      return 'warning';
    default:
      return 'muted';
  }
}
