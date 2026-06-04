'use client';

import {BadgeCheck, ChevronsUpDown, LogOut} from 'lucide-react';
import Link from 'next/link';

import {logout} from '@/app/actions/session';
import {Avatar, AvatarFallback, AvatarImage} from '@/components/ui/avatar';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar';
import {useGenericVimShortcutListener} from '@/hooks/use-keyboard-shortcut-listener';
import {UserData} from '@/lib/typings';

export function NavUser({
  user,
}: Readonly<{
  user: UserData;
}>) {
  const {isMobile} = useSidebar();
  const profileImage = user.profile_picture_url ?? '/logo.svg';
  const fallbackName = user.displayName
    .split(' ')
    .map(n => n.charAt(0))
    .join('')
    .toUpperCase();

  useGenericVimShortcutListener('q', () => logout());

  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <SidebarMenuButton
              className="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
              size="lg"
            >
              <Avatar className="size-8 rounded-lg bg-muted p-1">
                <AvatarImage
                  alt={user.displayName}
                  {...(profileImage ? {src: profileImage} : {})}
                />
                <AvatarFallback className="rounded-lg">
                  {fallbackName}
                </AvatarFallback>
              </Avatar>
              <div className="grid flex-1 text-left text-sm leading-tight">
                <span className="truncate font-medium">{user.displayName}</span>
                <span className="truncate text-xs">{user.username}</span>
              </div>
              <ChevronsUpDown className="ml-auto size-4" />
            </SidebarMenuButton>
          </DropdownMenuTrigger>
          <DropdownMenuContent
            align="end"
            className="w-(--radix-dropdown-menu-trigger-width) min-w-56 rounded-lg"
            side={isMobile ? 'bottom' : 'right'}
            sideOffset={4}
          >
            <DropdownMenuLabel className="p-0 font-normal">
              <div className="flex items-center gap-2 px-1 py-1.5 text-left text-sm">
                <Avatar className="size-8 rounded-lg bg-muted p-1">
                  <AvatarImage
                    alt={user.displayName}
                    {...(profileImage ? {src: profileImage} : {})}
                  />
                  <AvatarFallback className="rounded-lg">
                    {fallbackName}
                  </AvatarFallback>
                </Avatar>
                <div className="grid flex-1 text-left text-sm leading-tight">
                  <span className="truncate font-medium">
                    {user.displayName}
                  </span>
                  <span className="truncate text-xs">{user.username}</span>
                </div>
              </div>
            </DropdownMenuLabel>
            <DropdownMenuSeparator />
            <DropdownMenuGroup>
              <DropdownMenuItem>
                <Link
                  className="flex items-center gap-2 w-full"
                  href="/dashboard/profile"
                >
                  <BadgeCheck />
                  Profile
                </Link>
              </DropdownMenuItem>
            </DropdownMenuGroup>
            <DropdownMenuSeparator />
            <DropdownMenuItem onClick={() => logout()}>
              <LogOut />
              Log out
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}
