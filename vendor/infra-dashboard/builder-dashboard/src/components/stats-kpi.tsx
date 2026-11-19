'use client';

import {useEffect, useMemo, useState} from 'react';

import {getPackageStats} from '@/app/actions/stats';
import {KPICard} from '@/components/kpi-card';
import {useSidebar} from '@/components/ui/sidebar';
import {PackageStatsList, PackageStatsType, PackageStatus} from '@/lib/typings';
import {
  getColorClassNameByPackageStatus,
  getVariantByPackageStatus,
} from '@/lib/utils';

export function StatsKPI({
  statusFilterUpdate,
}: Readonly<{
  statusFilterUpdate: (status: PackageStatus) => void;
}>) {
  const {activeServer} = useSidebar();
  const [categoryChartData, setCategoryChartData] = useState<PackageStatsList>(
    []
  );
  const processedChartData = useMemo(
    () =>
      categoryChartData.filter(
        x =>
          x.status_name === PackageStatus.LATEST ||
          x.status_name === PackageStatus.BUILDING ||
          x.status_name === PackageStatus.QUEUED ||
          x.status_name === PackageStatus.FAILED
      ),
    [categoryChartData]
  );
  const packageCount = useMemo(
    () => categoryChartData.reduce((acc, item) => acc + item.package_count, 0),
    [categoryChartData]
  );
  useEffect(() => {
    setCategoryChartData([]);
    getPackageStats(PackageStatsType.CATEGORY).then(response => {
      if (Array.isArray(response)) {
        setCategoryChartData(response);
      }
    });
  }, [activeServer]);
  return (
    <div className="flex flex-col md:flex-row w-full gap-4 max-w-7xl flex-wrap mx-auto items-center justify-center">
      {processedChartData.map(item => (
        <KPICard
          badgeClassName={getColorClassNameByPackageStatus(item.status_name)}
          count={item.package_count}
          item={item.status_name}
          key={item.status_name}
          maxCount={packageCount}
          onClick={statusFilterUpdate}
          progressCircleVariant={getVariantByPackageStatus(item.status_name)}
        />
      ))}
    </div>
  );
}
