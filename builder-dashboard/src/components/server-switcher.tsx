'use client';

import {ChevronsUpDown, RefreshCw} from 'lucide-react';
import Image from 'next/image';
import * as React from 'react';
import {toast} from 'sonner';

import {changeServer, retryServerAccess} from '@/app/actions/session';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuShortcut,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {Kbd} from '@/components/ui/kbd';
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from '@/components/ui/sidebar';
import {
  useNumericKeyShortcutListener,
  useNumericKeyVimShortcutListener,
} from '@/hooks/use-keyboard-shortcut-listener';
import {ServerData} from '@/lib/typings';
import {cn} from '@/lib/utils';

const ERROR_TOAST_OPTS = {
  closeButton: true,
  duration: Infinity,
} as const;

export function ServerSwitcher({
  servers,
}: Readonly<{
  servers: ServerData[];
}>) {
  const {
    doRefresh,
    isMobile,
    setActiveServer: updateActiveServer,
  } = useSidebar();
  const [retrying, setRetrying] = React.useState<null | string>(null);

  const activeServer = React.useMemo<null | ServerData>(() => {
    if (servers.length === 0) return null;
    return servers.find(s => s.active && s.accessible) ?? servers[0];
  }, [servers]);

  const handleServerChange = React.useCallback(
    (server: ServerData) => {
      if (
        !server.accessible ||
        !activeServer ||
        server.name === activeServer.name
      ) {
        return;
      }
      const toastId = toast.loading(`Switching to server "${server.name}"...`);
      changeServer(server.name)
        .then(res => {
          if (res.error) {
            toast.error(res.error, {...ERROR_TOAST_OPTS, id: toastId});
            return;
          }
          updateActiveServer(server.name);
          toast.success(res.msg ?? 'Switched server successfully!', {
            id: toastId,
          });
        })
        .catch(() => {
          toast.error('Failed to switch server, please try again later.', {
            ...ERROR_TOAST_OPTS,
            id: toastId,
          });
        });
    },
    [activeServer, updateActiveServer]
  );

  const handleRetryAccess = React.useCallback(
    (server: ServerData) => {
      if (retrying) return;
      setRetrying(server.name);
      const toastId = toast.loading(`Retrying access on "${server.name}"...`);
      retryServerAccess(server.name)
        .then(res => {
          if (res.error) {
            toast.error(res.error, {...ERROR_TOAST_OPTS, id: toastId});
            return;
          }
          toast.success(res.msg ?? `Restored access to "${server.name}".`, {
            id: toastId,
          });
          doRefresh();
        })
        .catch(() => {
          toast.error(`Failed to retry access on "${server.name}".`, {
            ...ERROR_TOAST_OPTS,
            id: toastId,
          });
        })
        .finally(() => {
          setRetrying(null);
        });
    },
    [doRefresh, retrying]
  );

  const handleServerSwitchShortcut = React.useCallback(
    (key: number) => {
      const server = servers[key - 1];
      if (server?.accessible) {
        handleServerChange(server);
      }
    },
    [handleServerChange, servers]
  );

  useNumericKeyShortcutListener(handleServerSwitchShortcut);
  useNumericKeyVimShortcutListener(handleServerSwitchShortcut);

  if (!activeServer) {
    return null;
  }

  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <SidebarMenuButton
              className="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
              size="lg"
            >
              <div className="bg-muted text-sidebar-primary-foreground flex aspect-square size-8 items-center justify-center rounded-lg">
                <ServerLogo size="lg" />
              </div>
              <div className="grid flex-1 text-left text-sm leading-tight">
                <span className="truncate font-medium">
                  {activeServer.name}
                </span>
                <span className="truncate text-xs">
                  {activeServer.description}
                </span>
              </div>
              <ChevronsUpDown className="ml-auto" />
            </SidebarMenuButton>
          </DropdownMenuTrigger>
          <DropdownMenuContent
            align="start"
            className="w-(--radix-dropdown-menu-trigger-width) min-w-56 rounded-lg"
            side={isMobile ? 'bottom' : 'right'}
            sideOffset={4}
          >
            <DropdownMenuLabel className="text-muted-foreground text-xs">
              Build Servers
            </DropdownMenuLabel>
            {servers.map((server, index) => (
              <ServerSwitcherItem
                index={index}
                isRetrying={retrying === server.name}
                key={server.name}
                onRetry={handleRetryAccess}
                onSwitch={handleServerChange}
                server={server}
              />
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
      </SidebarMenuItem>
    </SidebarMenu>
  );
}

function ServerLogo({size}: {size: 'lg' | 'sm'}) {
  const dim = size === 'lg' ? 'size-7' : 'size-4';
  return (
    <Image
      alt="Logo"
      className={dim}
      height={32}
      src="/logo.svg"
      width={32}
    />
  );
}

function ServerSwitcherItem({
  index,
  isRetrying,
  onRetry,
  onSwitch,
  server,
}: {
  index: number;
  isRetrying: boolean;
  onRetry: (server: ServerData) => void;
  onSwitch: (server: ServerData) => void;
  server: ServerData;
}) {
  return (
    <DropdownMenuItem
      className="gap-2 p-2"
      disabled={isRetrying}
      onSelect={e => {
        if (server.accessible) {
          onSwitch(server);
        } else {
          e.preventDefault();
          onRetry(server);
        }
      }}
    >
      <div className="flex size-6 items-center justify-center rounded-md border">
        <ServerLogo size="sm" />
      </div>
      <span className={cn(!server.accessible && 'text-muted-foreground')}>
        {server.name}
      </span>
      <DropdownMenuShortcut>
        {server.accessible ? (
          <Kbd>⌘ {index + 1}</Kbd>
        ) : (
          <span className="text-muted-foreground inline-flex items-center gap-1 text-xs">
            <RefreshCw className={cn('size-3', isRetrying && 'animate-spin')} />
            Retry
          </span>
        )}
      </DropdownMenuShortcut>
    </DropdownMenuItem>
  );
}
