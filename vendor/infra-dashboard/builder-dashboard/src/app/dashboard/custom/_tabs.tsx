'use client';

import {FileCheck, GitBranch, Package, Shield} from 'lucide-react';
import Link from 'next/link';
import {usePathname} from 'next/navigation';
import {useMemo} from 'react';

import {useSidebar} from '@/components/ui/sidebar';
import {Tabs, TabsList, TabsTrigger} from '@/components/ui/tabs';
import {UserScope} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

const baseTabs = [
  {
    href: '/dashboard/custom/repos',
    icon: GitBranch,
    key: 'repos',
    label: 'Repos',
  },
  {
    href: '/dashboard/custom/packages',
    icon: Package,
    key: 'packages',
    label: 'Packages',
  },
  {
    href: '/dashboard/custom/submissions',
    icon: FileCheck,
    key: 'submissions',
    label: 'Submissions',
  },
] as const;

export function CustomTabs() {
  const pathname = usePathname();
  const {scopes} = useSidebar();
  const isAdmin = checkScopes(scopes, [UserScope.ADMIN]);

  const tabs = useMemo(() => {
    if (!isAdmin) return baseTabs;
    return [
      ...baseTabs,
      {
        href: '/dashboard/custom/maintainers',
        icon: Shield,
        key: 'maintainers',
        label: 'Maintainers',
      } as const,
    ];
  }, [isAdmin]);

  const active = useMemo(() => {
    const found = tabs.find(t => pathname?.startsWith(t.href));
    return found?.key ?? 'repos';
  }, [pathname, tabs]);

  return (
    <Tabs value={active}>
      <TabsList variant="line">
        {tabs.map(tab => (
          <TabsTrigger asChild key={tab.key} value={tab.key}>
            <Link href={tab.href}>
              <tab.icon />
              {tab.label}
            </Link>
          </TabsTrigger>
        ))}
      </TabsList>
    </Tabs>
  );
}
