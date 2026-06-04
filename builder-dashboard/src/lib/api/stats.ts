import {
  BuildTimeStatsDataList,
  PackageStatsByMonthList,
  PackageStatsByMonthListSchema,
  PackageStatsList,
  PackageStatsListSchema,
} from '@/lib/typings';

import {BaseClient} from './base';
import {emptyOn404, parseOrThrow} from './helpers';

export class StatsClient {
  constructor(private base: BaseClient) {}

  public async getBuildTimePackageStats(clientHeaders = new Headers()) {
    const response = await emptyOn404<BuildTimeStatsDataList>(
      () =>
        this.base._fetcher<BuildTimeStatsDataList>({
          clientHeaders,
          endpoint: 'packages-stats?stat_type=build_time',
        }),
      []
    );
    return parseOrThrow(
      BuildTimeStatsDataList,
      response,
      'build time package stats response'
    );
  }

  public async getPackageStatsByCategory(clientHeaders = new Headers()) {
    const response = await emptyOn404<PackageStatsList>(
      () =>
        this.base._fetcher<PackageStatsList>({
          clientHeaders,
          endpoint: 'packages-stats?stat_type=category',
        }),
      []
    );
    return parseOrThrow(
      PackageStatsListSchema,
      response,
      'package stats response'
    );
  }

  public async getPackageStatsByMonth(clientHeaders = new Headers()) {
    const response = await emptyOn404<PackageStatsByMonthList>(
      () =>
        this.base._fetcher<PackageStatsByMonthList>({
          clientHeaders,
          endpoint: 'packages-stats?stat_type=month',
        }),
      []
    );
    return parseOrThrow(
      PackageStatsByMonthListSchema,
      response,
      'monthly package stats response'
    );
  }
}
