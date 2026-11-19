import * as React from 'react';

import {cn} from '@/lib/utils';

import {StatusDot, type StatusTone} from './status-dot';

export interface TimelineEvent {
  body?: React.ReactNode;
  id: string;
  meta?: React.ReactNode;
  pulse?: boolean;
  title: React.ReactNode;
  tone: StatusTone;
}

interface TimelineProps extends React.HTMLAttributes<HTMLOListElement> {
  events: ReadonlyArray<TimelineEvent>;
}

export function Timeline({className, events, ...props}: TimelineProps) {
  return (
    <ol className={cn('relative flex flex-col gap-0', className)} {...props}>
      {events.map((event, idx) => {
        const isLast = idx === events.length - 1;
        return (
          <li className="relative flex gap-3 pb-5 last:pb-0" key={event.id}>
            {!isLast && (
              <span
                aria-hidden
                className="absolute left-[3px] top-3 h-full w-px bg-border"
              />
            )}
            <span className="relative z-10 mt-1.5 flex shrink-0">
              <StatusDot pulse={event.pulse} tone={event.tone} />
            </span>
            <div className="flex min-w-0 flex-col gap-0.5">
              <div className="flex flex-wrap items-baseline gap-x-2">
                <span className="text-sm font-medium">{event.title}</span>
                {event.meta && (
                  <span className="text-xs text-muted-foreground">
                    {event.meta}
                  </span>
                )}
              </div>
              {event.body && (
                <div className="text-sm text-muted-foreground">
                  {event.body}
                </div>
              )}
            </div>
          </li>
        );
      })}
    </ol>
  );
}
