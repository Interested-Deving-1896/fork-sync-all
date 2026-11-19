'use client';

import prettyBytes from 'pretty-bytes';
import prettyMilliseconds from 'pretty-ms';
import {useMemo} from 'react';
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Label,
  Pie,
  PieChart,
  XAxis,
  YAxis,
} from 'recharts';
import {
  NameType,
  ValueType,
} from 'recharts/types/component/DefaultTooltipContent';

import {
  ChartConfig,
  ChartConfigValue,
  ChartContainer,
  ChartLegend,
  ChartLegendContent,
  ChartTooltip,
  ChartTooltipContent,
} from '@/components/ui/chart';
import {
  BuildTimeStatsDataList,
  MonthlyChartData,
  PackageStatsList,
  PackageStatus,
  packageStatusValues,
} from '@/lib/typings';

const chartConfig: Record<PackageStatus, ChartConfigValue> = {
  BUILDING: {
    color: 'var(--chart-1)',
    label: 'Building',
  },
  CANCELLED: {
    color: 'var(--chart-8)',
    label: 'Cancelled',
  },
  DONE: {
    color: 'var(--chart-2)',
    label: 'Done',
  },
  FAILED: {
    color: 'var(--chart-3)',
    label: 'Failed',
  },
  LATEST: {
    color: 'var(--chart-4)',
    label: 'Latest',
  },
  QUEUED: {
    color: 'var(--chart-5)',
    label: 'Queued',
  },
  SKIPPED: {
    color: 'var(--chart-6)',
    label: 'Skipped',
  },
  UNKNOWN: {
    color: 'var(--chart-7)',
    label: 'Unknown',
  },
} satisfies ChartConfig;

const buildTimeBarChartConfig = {
  average_build_time: {
    color: 'var(--chart-2)',
    label: 'Avg. Build Time',
  },
  average_user_time: {
    color: 'var(--chart-1)',
    label: 'Avg. User Time',
  },
} satisfies ChartConfig;

const buildMemoryBarChartConfig = {
  average_max_rss: {
    color: 'var(--chart-1)',
    label: 'Avg. Max RSS',
  },
} satisfies ChartConfig;

export function BuildStatsMemoryBarChart({
  chartData,
}: Readonly<{
  chartData: BuildTimeStatsDataList;
}>) {
  const processedChartData = useMemo(
    () =>
      chartData
        .map(item => ({
          ...item,
          key: `${item.march} - ${item.repository}`,
        }))
        .toSorted((a, b) => a.march.localeCompare(b.march))
        .toSorted((a, b) => a.repository.localeCompare(b.repository)),
    [chartData]
  );
  return (
    <ChartContainer config={buildMemoryBarChartConfig}>
      <BarChart accessibilityLayer data={processedChartData}>
        <CartesianGrid vertical={false} />
        <XAxis
          axisLine={false}
          dataKey="key"
          tickLine={false}
          tickMargin={10}
        />
        <ChartTooltip
          content={
            <ChartTooltipContent
              contentFormatter={buildStatsMemoryContentFormatter}
              hideLabel
            />
          }
          cursor={false}
        />
        <ChartLegend content={<ChartLegendContent />} />
        <Bar
          dataKey="average_max_rss"
          fill="var(--color-average_max_rss)"
          radius={[0, 0, 4, 4]}
        />
      </BarChart>
    </ChartContainer>
  );
}

export function BuildStatsTimeBarChart({
  chartData,
}: Readonly<{
  chartData: BuildTimeStatsDataList;
}>) {
  const processedChartData = useMemo(
    () =>
      chartData
        .map(item => ({
          ...item,
          key: `${item.march} - ${item.repository}`,
          total: item.average_build_time + item.average_user_time,
        }))
        .toSorted((a, b) => a.march.localeCompare(b.march))
        .toSorted((a, b) => a.repository.localeCompare(b.repository)),
    [chartData]
  );
  return (
    <ChartContainer config={buildTimeBarChartConfig}>
      <BarChart accessibilityLayer data={processedChartData}>
        <CartesianGrid vertical={false} />
        <XAxis
          axisLine={false}
          dataKey="key"
          tickLine={false}
          tickMargin={10}
        />
        <YAxis tickFormatter={buildStatsTimeTickFormatter} />
        <ChartTooltip
          content={
            <ChartTooltipContent
              contentFormatter={buildStatsTimeContentFormatter}
              hideLabel
            />
          }
          cursor={false}
        />
        <ChartLegend content={<ChartLegendContent />} />
        <Bar
          dataKey="average_user_time"
          fill="var(--color-average_user_time)"
          radius={[0, 0, 4, 4]}
        />
        <Bar
          dataKey="average_build_time"
          fill="var(--color-average_build_time)"
          radius={[4, 4, 0, 0]}
        />
      </BarChart>
    </ChartContainer>
  );
}

export function CategoryStatsDonutChart({
  chartData,
}: Readonly<{chartData: PackageStatsList}>) {
  const processedChartData = useMemo(
    () =>
      chartData
        .filter(item => item.package_count > 0)
        .map(item => ({
          ...item,
          fill: chartConfig[item.status_name].color,
        })),
    [chartData]
  );
  const totalPackages = useMemo(
    () => chartData.reduce((acc, item) => acc + item.package_count, 0),
    [chartData]
  );
  return (
    <ChartContainer
      className="[&_.recharts-pie-label-text]:fill-foreground mx-auto aspect-square max-h-128 pb-0"
      config={chartConfig}
    >
      <PieChart>
        <ChartTooltip content={<ChartTooltipContent hideLabel />} />
        <Pie
          data={processedChartData}
          dataKey="package_count"
          innerRadius={60}
          label
          nameKey="status_name"
          outerRadius={80}
        >
          {!!totalPackages && (
            <Label
              className="fill-foreground text-2xl font-bold"
              position="center"
              value={totalPackages}
            />
          )}
        </Pie>
        <ChartLegend
          className="-translate-y-2 flex-wrap gap-2 *:basis-1/4 *:justify-center"
          content={<ChartLegendContent nameKey="status_name" />}
        />
      </PieChart>
    </ChartContainer>
  );
}

export function MonthlyStatsAreaChart({
  chartData,
}: Readonly<{
  chartData: MonthlyChartData;
}>) {
  return (
    <ChartContainer config={chartConfig}>
      <AreaChart
        accessibilityLayer
        data={chartData}
        margin={{
          left: 12,
          right: 12,
        }}
      >
        <CartesianGrid vertical={false} />
        <XAxis
          axisLine={false}
          dataKey="reporting_month"
          tickLine={false}
          tickMargin={8}
        />
        <ChartTooltip content={<ChartTooltipContent />} cursor={false} />
        <defs>
          {packageStatusValues.map(status => (
            <linearGradient
              id={`fill${status}`}
              key={status}
              x1="0"
              x2="0"
              y1="0"
              y2="1"
            >
              <stop
                offset="5%"
                stopColor={chartConfig[status].color}
                stopOpacity={0.8}
              />
              <stop
                offset="95%"
                stopColor={chartConfig[status].color}
                stopOpacity={0.1}
              />
            </linearGradient>
          ))}
        </defs>
        {packageStatusValues.map(status => (
          <Area
            dataKey={status}
            fill={`url(#fill${status})`}
            fillOpacity={0.4}
            key={`monthly-chart-area-${status}`}
            stroke={chartConfig[status].color}
            type="bump"
          />
        ))}
        <ChartLegend content={<ChartLegendContent />} />
      </AreaChart>
    </ChartContainer>
  );
}

function buildStatsMemoryContentFormatter(value: ValueType, name: NameType) {
  if (name === 'average_max_rss' && typeof value === 'number') {
    return prettyBytes(value * 1024);
  }
  return value.toLocaleString();
}

function buildStatsTimeContentFormatter(value: ValueType, name?: NameType) {
  if (
    (!name || name === 'average_user_time' || name === 'average_build_time') &&
    typeof value === 'number'
  ) {
    return prettyMilliseconds(value * 1000);
  }
  return value.toLocaleString();
}

function buildStatsTimeTickFormatter(value: ValueType) {
  if (typeof value === 'number') {
    return prettyMilliseconds(value * 1000);
  }
  return value.toLocaleString();
}
