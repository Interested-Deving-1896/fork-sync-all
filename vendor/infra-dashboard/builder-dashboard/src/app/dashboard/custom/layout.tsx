import * as React from 'react';

import {CustomTabs} from './_tabs';

export default function CustomLayout({
  children,
}: Readonly<{children: React.ReactNode}>) {
  return (
    <div className="flex flex-col gap-6">
      <CustomTabs />
      {children}
    </div>
  );
}
