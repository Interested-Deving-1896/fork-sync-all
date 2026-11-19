import * as React from 'react';

import {cn} from '@/lib/utils';

export type StatusTone =
  | 'building'
  | 'danger'
  | 'info'
  | 'muted'
  | 'success'
  | 'warning';

const toneClass: Record<StatusTone, string> = {
  building: 'bg-brand',
  danger: 'bg-status-danger',
  info: 'bg-status-info',
  muted: 'bg-status-muted',
  success: 'bg-status-success',
  warning: 'bg-status-warning',
};

const ringClass: Record<StatusTone, string> = {
  building: 'ring-brand/30',
  danger: 'ring-status-danger/30',
  info: 'ring-status-info/30',
  muted: 'ring-status-muted/30',
  success: 'ring-status-success/30',
  warning: 'ring-status-warning/30',
};

interface StatusDotProps extends React.HTMLAttributes<HTMLSpanElement> {
  pulse?: boolean;
  size?: 'md' | 'sm';
  tone: StatusTone;
}

export function StatusDot({
  className,
  pulse = false,
  size = 'md',
  tone,
  ...props
}: StatusDotProps) {
  const dim = size === 'sm' ? 'size-1.5' : 'size-2';
  return (
    <span
      aria-hidden
      className={cn(
        'relative inline-flex shrink-0 items-center justify-center',
        className
      )}
      {...props}
    >
      {pulse && (
        <span
          className={cn(
            'absolute inline-flex animate-ping rounded-full opacity-60',
            dim,
            toneClass[tone]
          )}
        />
      )}
      <span
        className={cn(
          'relative inline-flex rounded-full ring-2',
          dim,
          toneClass[tone],
          ringClass[tone]
        )}
      />
    </span>
  );
}
