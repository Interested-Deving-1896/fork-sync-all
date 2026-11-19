import {
  IconAlertCircleFilled,
  IconCircleCheckFilled,
  IconCircleChevronsRightFilled,
  IconLoader,
  IconMinus,
  IconPlus,
  IconProgressHelp,
} from '@tabler/icons-react';
import {type ClassValue, clsx} from 'clsx';
import {twMerge} from 'tailwind-merge';

import {ProgressCircleVariants} from '@/components/ui/progress-circle';
import {PackageStatus, RepoActionType, UserScope} from '@/lib/typings';

export function checkScopes(
  userScopes: UserScope[],
  requiredScopes: UserScope[]
) {
  return requiredScopes.every(scope => userScopes.includes(scope));
}

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function getColorClassNameByPackageStatus(status: PackageStatus) {
  switch (status) {
    case PackageStatus.BUILDING:
      return 'border-yellow-500 text-yellow-500 bg-yellow-100 dark:bg-yellow-500/10 dark:text-yellow-500';
    case PackageStatus.DONE:
    case PackageStatus.LATEST:
    case PackageStatus.SKIPPED:
      return 'border-green-500 text-green-500 bg-green-100 dark:bg-green-500/10 dark:text-green-500';
    case PackageStatus.FAILED:
      return 'border-red-500 text-red-500 bg-red-100 dark:bg-red-500/10 dark:text-red-500';
    case PackageStatus.QUEUED:
      return 'border-blue-500 text-blue-500 bg-blue-100 dark:bg-blue-500/10 dark:text-blue-500';
    case PackageStatus.UNKNOWN:
    default:
      return 'border-gray-500 text-gray-500 bg-gray-100 dark:bg-gray-500/10 dark:text-gray-500';
  }
}

export function getColorClassNameByScope(scope: UserScope) {
  switch (scope) {
    case UserScope.ADMIN:
      return 'text-red-500 bg-red-100 dark:bg-red-500/10 dark:text-red-500';
    case UserScope.READ:
      return 'text-blue-500 bg-blue-100 dark:bg-blue-500/10 dark:text-blue-500';
    case UserScope.WRITE:
      return 'text-green-500 bg-green-100 dark:bg-green-500/10 dark:text-green-500';
    default:
      return 'text-gray-500 bg-gray-100 dark:bg-gray-500/10 dark:text-gray-500';
  }
}

export function getVariantByPackageStatus(
  status: PackageStatus
): ProgressCircleVariants {
  switch (status) {
    case PackageStatus.BUILDING:
      return 'warning';
    case PackageStatus.DONE:
    case PackageStatus.LATEST:
    case PackageStatus.SKIPPED:
      return 'success';
    case PackageStatus.FAILED:
      return 'error';
    case PackageStatus.QUEUED:
      return 'default';
    case PackageStatus.UNKNOWN:
    default:
      return 'neutral';
  }
}

export function packageStatusToIcon(status: PackageStatus) {
  switch (status) {
    case PackageStatus.BUILDING:
      return <IconLoader className="size-5" />;
    case PackageStatus.DONE:
      return <IconCircleCheckFilled className="fill-green-500 size-5" />;
    case PackageStatus.FAILED:
      return <IconAlertCircleFilled className="fill-red-500 size-5" />;
    case PackageStatus.LATEST:
      return <IconCircleCheckFilled className="fill-green-500 size-5" />;
    case PackageStatus.QUEUED:
      return <IconLoader className="size-5" />;
    case PackageStatus.SKIPPED:
      return (
        <IconCircleChevronsRightFilled className="fill-yellow-500 size-5" />
      );
    default:
      return (
        <IconProgressHelp className="fill-gray-500 size-5 stroke-gray-50" />
      );
  }
}

export function repoActionTypeToIcon(actionType: RepoActionType) {
  switch (actionType) {
    case RepoActionType.ADDITION:
      return <IconPlus className="stroke-green-500 size-5" />;
    case RepoActionType.REMOVAL:
      return <IconMinus className="stroke-red-500 size-5" />;
    default:
      return (
        <IconProgressHelp className="fill-gray-500 size-5 stroke-gray-50" />
      );
  }
}

export function unixToDate(seconds: number): Date {
  return new Date(seconds * 1000);
}
