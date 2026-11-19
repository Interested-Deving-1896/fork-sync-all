import type {StatusTone} from '@/components/ui/status-dot';

import {SubmissionStatus} from '@/lib/typings';

export const submissionStatusTone: Record<SubmissionStatus, StatusTone> = {
  [SubmissionStatus.APPROVED]: 'info',
  [SubmissionStatus.BUILD_DONE]: 'success',
  [SubmissionStatus.BUILD_FAILED]: 'danger',
  [SubmissionStatus.BUILD_QUEUED]: 'building',
  [SubmissionStatus.BUILD_SKIPPED]: 'muted',
  [SubmissionStatus.CANCELLED]: 'muted',
  [SubmissionStatus.PENDING_REVIEW]: 'warning',
  [SubmissionStatus.REJECTED]: 'danger',
};

const submissionStatusPulse: Partial<Record<SubmissionStatus, true>> = {
  [SubmissionStatus.BUILD_QUEUED]: true,
  [SubmissionStatus.PENDING_REVIEW]: true,
};

const submissionStatusLabels: Record<SubmissionStatus, string> = {
  [SubmissionStatus.APPROVED]: 'Approved',
  [SubmissionStatus.BUILD_DONE]: 'Build done',
  [SubmissionStatus.BUILD_FAILED]: 'Build failed',
  [SubmissionStatus.BUILD_QUEUED]: 'Build queued',
  [SubmissionStatus.BUILD_SKIPPED]: 'Build skipped',
  [SubmissionStatus.CANCELLED]: 'Cancelled',
  [SubmissionStatus.PENDING_REVIEW]: 'Pending review',
  [SubmissionStatus.REJECTED]: 'Rejected',
};

export function labelFor(status: string | SubmissionStatus): string {
  return submissionStatusLabels[status as SubmissionStatus] ?? status;
}

export function pulseFor(status: string | SubmissionStatus): boolean {
  return submissionStatusPulse[status as SubmissionStatus] ?? false;
}

export function toneFor(status: string | SubmissionStatus): StatusTone {
  return submissionStatusTone[status as SubmissionStatus] ?? 'muted';
}
