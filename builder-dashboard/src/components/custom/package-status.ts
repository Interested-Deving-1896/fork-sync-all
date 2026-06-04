import type {StatusTone} from '@/components/ui/status-dot';

import {PackageStatus} from '@/lib/typings';

type PackageBadgeVariant =
  | 'building'
  | 'danger'
  | 'info'
  | 'muted'
  | 'success'
  | 'warning';

export const packageStatusTone: Record<PackageStatus, StatusTone> = {
  [PackageStatus.BUILDING]: 'building',
  [PackageStatus.CANCELLED]: 'muted',
  [PackageStatus.DONE]: 'success',
  [PackageStatus.FAILED]: 'danger',
  [PackageStatus.LATEST]: 'success',
  [PackageStatus.QUEUED]: 'warning',
  [PackageStatus.SKIPPED]: 'muted',
  [PackageStatus.UNKNOWN]: 'muted',
};

export const packageStatusVariant: Record<PackageStatus, PackageBadgeVariant> =
  {
    [PackageStatus.BUILDING]: 'building',
    [PackageStatus.CANCELLED]: 'muted',
    [PackageStatus.DONE]: 'success',
    [PackageStatus.FAILED]: 'danger',
    [PackageStatus.LATEST]: 'success',
    [PackageStatus.QUEUED]: 'warning',
    [PackageStatus.SKIPPED]: 'muted',
    [PackageStatus.UNKNOWN]: 'muted',
  };

const packageStatusLabels: Record<PackageStatus, string> = {
  [PackageStatus.BUILDING]: 'Building',
  [PackageStatus.CANCELLED]: 'Cancelled',
  [PackageStatus.DONE]: 'Done',
  [PackageStatus.FAILED]: 'Failed',
  [PackageStatus.LATEST]: 'Latest',
  [PackageStatus.QUEUED]: 'Queued',
  [PackageStatus.SKIPPED]: 'Skipped',
  [PackageStatus.UNKNOWN]: 'Unknown',
};

export function labelFor(status: PackageStatus | string): string {
  return packageStatusLabels[status as PackageStatus] ?? status;
}

export function pulseFor(status: PackageStatus | string): boolean {
  return status === PackageStatus.BUILDING;
}

export function toneFor(status: PackageStatus | string): StatusTone {
  return packageStatusTone[status as PackageStatus] ?? 'muted';
}

export function variantFor(
  status: PackageStatus | string
): PackageBadgeVariant {
  return packageStatusVariant[status as PackageStatus] ?? 'muted';
}
