'use client';

import {useMemo} from 'react';

import {Badge} from '@/components/ui/badge';
import {Card} from '@/components/ui/card';
import {
  ProgressCircle,
  ProgressCircleVariants,
} from '@/components/ui/progress-circle';

export interface KPICardProps<T> {
  badgeClassName: string;
  count: number;
  item: T;
  maxCount: number;
  onClick?: (item: T) => void;
  progressCircleVariant: ProgressCircleVariants;
}

export function KPICard<T extends string>({
  badgeClassName,
  count,
  item,
  maxCount,
  onClick,
  progressCircleVariant,
}: Readonly<KPICardProps<T>>) {
  const progress = useMemo(
    () => Number.parseFloat(((count / maxCount) * 100).toFixed(2)),
    [count, maxCount]
  );
  return (
    <Card
      className="p-4 w-72 grow hover:cursor-pointer hover:bg-accent"
      onClick={() => onClick?.(item)}
    >
      <div className="flex items-center justify-between">
        <p className="text-foreground">
          <span className="focus:outline-none capitalize">
            {item.toLocaleLowerCase()} packages
          </span>
        </p>
        <Badge className={badgeClassName}>{progress}%</Badge>
      </div>
      <div className="flex items-center justify-between pt-2">
        <p className="mt-3 flex items-end">
          <span className="text-2xl font-semibold">{count}</span>
          <span className="font-semibold text-sm text-muted-foreground">
            /{maxCount}
          </span>
        </p>
        <ProgressCircle value={progress} variant={progressCircleVariant}>
          <span className="text-xs font-medium">{progress}%</span>
        </ProgressCircle>
      </div>
    </Card>
  );
}
