import * as React from 'react';

import {cn} from '@/lib/utils';

interface FilterToolbarProps extends React.HTMLAttributes<HTMLDivElement> {
  selection?: boolean;
}

export function FilterToolbar({
  children,
  className,
  selection,
  ...props
}: FilterToolbarProps) {
  return (
    <div
      className={cn(
        'sticky top-0 z-10 -mx-4 flex flex-wrap items-center gap-2 border-b bg-background/90 px-4 py-3 backdrop-blur supports-[backdrop-filter]:bg-background/70',
        selection && 'border-brand/40 bg-brand/5',
        className
      )}
      {...props}
    >
      {children}
    </div>
  );
}
