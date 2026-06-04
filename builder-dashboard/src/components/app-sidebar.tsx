'use client';

import {
  Activity,
  Boxes,
  ChevronRight,
  FileCheck,
  GitBranch,
  Logs,
  Package,
  PieChart,
  Repeat2,
  Shield,
} from 'lucide-react';
import Link from 'next/link';
import * as React from 'react';
import {toast} from 'sonner';

import {getAccessibleServers, getLoggedInUser} from '@/app/actions/session';
import {NavMain} from '@/components/nav-main';
import {NavUser} from '@/components/nav-user';
import {ServerSwitcher} from '@/components/server-switcher';
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from '@/components/ui/collapsible';
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarRail,
  useSidebar,
} from '@/components/ui/sidebar';
import CachyBuilderClient from '@/lib/api';
import {UserData, UserScope} from '@/lib/typings';

const items = [
  {
    icon: Package,
    name: 'Package List',
    url: '/dashboard/package-list',
  },
  {
    icon: Repeat2,
    name: 'Rebuild Queue',
    url: '/dashboard/rebuild-queue',
  },
  {
    icon: Logs,
    name: 'Audit Logs',
    url: '/dashboard/audit-logs',
  },
  {
    icon: Activity,
    name: 'Repo Actions',
    url: '/dashboard/repo-actions',
  },
  {
    icon: PieChart,
    name: 'Statistics',
    url: '/dashboard/statistics',
  },
];

interface CustomSubItem {
  adminOnly?: boolean;
  icon: typeof GitBranch;
  name: string;
  tab: string;
}

const customSubItems: readonly CustomSubItem[] = [
  {icon: GitBranch, name: 'Repos', tab: 'repos'},
  {icon: Package, name: 'Packages', tab: 'packages'},
  {icon: FileCheck, name: 'Submissions', tab: 'submissions'},
  {adminOnly: true, icon: Shield, name: 'Maintainers', tab: 'maintainers'},
];

const INITIAL_USER: UserData = {
  displayName: 'Loading...',
  profile_picture_url: '/cachyos-logo.svg',
  scopes: [],
  username: 'Loading...',
};

export function AppSidebar({...props}: React.ComponentProps<typeof Sidebar>) {
  const {activeServer, refresh, setAuth} = useSidebar();
  const [servers, setServers] = React.useState(() =>
    CachyBuilderClient.servers.map(server => ({
      accessible: true,
      active: server.default,
      description: server.description,
      name: server.name,
    }))
  );
  const [user, setUser] = React.useState<UserData>(INITIAL_USER);
  React.useEffect(() => {
    getAccessibleServers().then(setServers);
  }, [activeServer, refresh]);

  React.useEffect(() => {
    getLoggedInUser(false).then(data => {
      if ('error' in data) {
        toast.error(data.error, {
          closeButton: true,
          duration: Infinity,
        });
        return;
      }
      setUser(data);
      setAuth({scopes: data.scopes, username: data.username});
    });
  }, [activeServer, refresh, setAuth]);

  const isAdmin = user.scopes.includes(UserScope.ADMIN);

  const customMenuItems: React.ReactNode[] = [];
  for (const sub of customSubItems) {
    if (sub.adminOnly && !isAdmin) continue;
    customMenuItems.push(
      <SidebarMenuSubItem key={sub.tab}>
        <SidebarMenuSubButton asChild>
          <Link href={`/dashboard/custom/${sub.tab}`}>
            <sub.icon />
            <span>{sub.name}</span>
          </Link>
        </SidebarMenuSubButton>
      </SidebarMenuSubItem>
    );
  }

  return (
    <Sidebar collapsible="icon" {...props}>
      <SidebarHeader>
        <ServerSwitcher servers={servers} />
      </SidebarHeader>
      <SidebarContent>
        <NavMain items={items} />
        <SidebarGroup>
          <Collapsible className="group/collapsible" defaultOpen>
            <SidebarGroupLabel
              asChild
              className="text-sm font-semibold text-sidebar-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground"
            >
              <CollapsibleTrigger>
                <Boxes />
                <span>Custom</span>
                <ChevronRight className="ml-auto transition-transform duration-200 group-data-[state=open]/collapsible:rotate-90" />
              </CollapsibleTrigger>
            </SidebarGroupLabel>
            <CollapsibleContent>
              <SidebarMenuSub>{customMenuItems}</SidebarMenuSub>
            </CollapsibleContent>
          </Collapsible>
        </SidebarGroup>
      </SidebarContent>
      <SidebarFooter>
        <NavUser user={user} />
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  );
}
