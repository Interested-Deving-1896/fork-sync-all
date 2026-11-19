'use server';

import {headers} from 'next/headers';
import {redirect} from 'next/navigation';

import {getSession} from '@/app/actions/session';
import {
  BuildTimeStatsDataList,
  PackageStatsList,
  PackageStatsType,
  ProcessedPackageStatsByMonthList,
} from '@/lib/typings';

export async function getPackageStats(
  type: PackageStatsType.CATEGORY
): Promise<PackageStatsList | {error: string}>;
export async function getPackageStats(
  type: PackageStatsType.MONTH
): Promise<ProcessedPackageStatsByMonthList | {error: string}>;
export async function getPackageStats(
  type: PackageStatsType.BUILD_TIME
): Promise<BuildTimeStatsDataList | {error: string}>;
export async function getPackageStats(
  type: PackageStatsType = PackageStatsType.CATEGORY
): Promise<
  | BuildTimeStatsDataList
  | PackageStatsList
  | ProcessedPackageStatsByMonthList
  | {error: string}
> {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    if (type === PackageStatsType.MONTH) {
      const stats = await cachyBuilderClient.stats.getPackageStatsByMonth(
        await headers()
      );
      return stats.map(stat => ({
        ...stat,
        reporting_month: new Date(stat.reporting_month * 1000)
          .toISOString()
          .slice(0, 7),
      }));
    } else if (type === PackageStatsType.CATEGORY) {
      return cachyBuilderClient.stats.getPackageStatsByCategory(
        await headers()
      );
    } else {
      return cachyBuilderClient.stats.getBuildTimePackageStats(await headers());
    }
  } catch (error) {
    return {
      error: `Failed to get package stats: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}
