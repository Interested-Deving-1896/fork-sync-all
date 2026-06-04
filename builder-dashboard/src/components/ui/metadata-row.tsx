import * as React from 'react';

import {cn} from '@/lib/utils';

export interface MetadataItem {
  label?: string;
  mono?: boolean;
  value: React.ReactNode;
}

interface MetadataRowProps extends React.HTMLAttributes<HTMLDivElement> {
  items: ReadonlyArray<false | MetadataItem | null | undefined>;
  separator?: React.ReactNode;
}

export function MetadataRow({
  className,
  items,
  separator = '·',
  ...props
}: MetadataRowProps) {
  const visible = items.filter((i): i is MetadataItem => Boolean(i));
  return (
    <div
      className={cn(
        'flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted-foreground',
        className
      )}
      {...props}
    >
      {visible.map((item, idx) => (
        <React.Fragment key={idx}>
          {idx > 0 && (
            <span aria-hidden className="text-muted-foreground/60">
              {separator}
            </span>
          )}
          <span
            className={cn(
              'inline-flex items-center gap-1',
              item.mono && 'font-mono'
            )}
          >
            {item.label && (
              <span className="text-muted-foreground/70">{item.label}:</span>
            )}
            <span className="text-foreground/80">{item.value}</span>
          </span>
        </React.Fragment>
      ))}
    </div>
  );
}
