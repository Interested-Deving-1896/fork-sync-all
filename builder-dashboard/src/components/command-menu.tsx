'use client';
import {
  Loader,
  RotateCcw,
  ScanSearch,
  SquareTerminal,
  User,
} from 'lucide-react';
import {useRouter} from 'next/navigation';
import {
  Fragment,
  KeyboardEventHandler,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {toast} from 'sonner';
import {useDebounce} from 'use-debounce';

import {rebuildPackage, searchPackages} from '@/app/actions/packages';
import {getUser} from '@/app/actions/users';
import {Avatar, AvatarFallback, AvatarImage} from '@/components/ui/avatar';
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandLoading,
  CommandSeparator,
} from '@/components/ui/command';
import {useSidebar} from '@/components/ui/sidebar';
import {useGenericShortcutListener} from '@/hooks/use-keyboard-shortcut-listener';
import {Package, PackageList, UserProfile} from '@/lib/typings';

enum CommandMenuOptions {
  REBUILD_PACKAGE,
  NO_OPTION_SELECTED,
  GET_PACKAGE_LOGS,
  USER_PROFILE,
}

export function CommandMenu() {
  const router = useRouter();
  const {activeServer} = useSidebar();
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [data, setData] = useState<null | PackageList>(null);
  const [searchQuery, setSearchQuery] = useState('');
  const [debouncedSearchQuery] = useDebounce(searchQuery, 800);
  const ref = useRef<HTMLInputElement>(null);
  const [selectedOption, setSelectedOption] = useState<CommandMenuOptions>(
    CommandMenuOptions.NO_OPTION_SELECTED
  );
  const [searchedUser, setSearchedUser] = useState<null | UserProfile>(null);
  const placeholder = useMemo(() => {
    switch (selectedOption) {
      case CommandMenuOptions.GET_PACKAGE_LOGS:
        return 'Search for a package to get logs ..';
      case CommandMenuOptions.REBUILD_PACKAGE:
        return 'Search for a package to rebuild...';
      case CommandMenuOptions.USER_PROFILE:
        return 'Type the username or hit enter to view your profile';
      default:
        return 'Type a command or search...';
    }
  }, [selectedOption]);
  const optionSelectCallback = useCallback(
    (option: CommandMenuOptions) => {
      if (selectedOption === option) {
        setSelectedOption(CommandMenuOptions.NO_OPTION_SELECTED);
      } else {
        setSelectedOption(option);
      }
      if (ref.current) {
        setSearchQuery('');
        ref.current.focus();
      }
    },
    [selectedOption]
  );
  const closeCommandMenu = useCallback(() => {
    setOpen(false);
    setSearchQuery('');
    setSearchedUser(null);
    setData(null);
    setSelectedOption(CommandMenuOptions.NO_OPTION_SELECTED);
  }, []);
  const packageSelectCallback = useCallback(
    (pkg: Package) => {
      if (selectedOption === CommandMenuOptions.GET_PACKAGE_LOGS) {
        closeCommandMenu();
        router.push(`/dashboard/logs/${pkg.march}/${pkg.pkgbase}`);
      } else if (selectedOption === CommandMenuOptions.REBUILD_PACKAGE) {
        const toastId = toast.loading(
          `Requesting rebuild for PkgBase: ${pkg.pkgbase} MArch: ${pkg.march} Repo: ${pkg.repository}...`
        );
        rebuildPackage(pkg.pkgbase, pkg.march, pkg.repository)
          .then(response => {
            if ('error' in response && response.error) {
              toast.error(`Failed to rebuild package: ${response.error}`, {
                closeButton: true,
                duration: Infinity,
                id: toastId,
              });
            } else if ('track_id' in response && response.track_id) {
              toast.success(
                `Rebuild request for PkgBase: ${pkg.pkgbase} MArch: ${pkg.march} Repo: ${pkg.repository} has been queued with Track ID: ${response.track_id}.`,
                {id: toastId}
              );
            }
          })
          .catch(error => {
            toast.error(
              `Failed to rebuild package: ${(error as Error)?.message ?? 'Something went wrong, please try again later'}`,
              {
                closeButton: true,
                duration: Infinity,
                id: toastId,
              }
            );
          });
      }
    },
    [closeCommandMenu, router, selectedOption]
  );
  const userProfileSelectCallback = useCallback(
    (user: string) => {
      closeCommandMenu();
      router.push(`/dashboard/profile/${user}`);
    },
    [closeCommandMenu, router]
  );
  const keyDownCallback: KeyboardEventHandler<HTMLInputElement> = useCallback(
    e => {
      if (e.key.toLowerCase() === 'backspace' && !searchQuery) {
        setSelectedOption(CommandMenuOptions.NO_OPTION_SELECTED);
      }
    },
    [searchQuery]
  );

  useEffect(() => {
    if (
      debouncedSearchQuery &&
      selectedOption !== CommandMenuOptions.NO_OPTION_SELECTED &&
      selectedOption !== CommandMenuOptions.USER_PROFILE
    ) {
      setLoading(true);
      searchPackages({
        search: debouncedSearchQuery,
      })
        .then(response => {
          if ('error' in response && response.error) {
            toast.error(`Failed to search packages: ${response.error}`, {
              closeButton: true,
              duration: Infinity,
            });
          } else if (Array.isArray(response)) {
            setData(response);
          }
        })
        .finally(() => {
          setLoading(false);
        });
    } else if (
      debouncedSearchQuery &&
      selectedOption === CommandMenuOptions.USER_PROFILE
    ) {
      setLoading(true);
      getUser(debouncedSearchQuery)
        .then(response => {
          if ('username' in response && response.username) {
            setSearchedUser({
              ...response,
              profile_picture_url:
                response.profile_picture_url ?? '/cachyos-logo.svg',
            });
          }
        })
        .finally(() => {
          setLoading(false);
        });
    }
  }, [activeServer, debouncedSearchQuery, selectedOption]);

  useEffect(() => {
    if (!debouncedSearchQuery && data) {
      setData(null);
    } else if (!debouncedSearchQuery && searchedUser) {
      setSearchedUser(null);
    }
  }, [data, debouncedSearchQuery, searchedUser]);

  useEffect(() => {
    return () => {
      setSearchedUser(null);
      setData(null);
      setSearchQuery('');
      setSelectedOption(CommandMenuOptions.NO_OPTION_SELECTED);
    };
  }, []);

  useGenericShortcutListener('k', () => setOpen(value => !value));
  useGenericShortcutListener('/', () => ref?.current?.focus(), true);

  return (
    <CommandDialog onOpenChange={setOpen} open={open}>
      <CommandInput
        onKeyDown={keyDownCallback}
        onValueChange={setSearchQuery}
        placeholder={placeholder}
        ref={ref}
        value={searchQuery}
      />
      <CommandList>
        {!loading && debouncedSearchQuery && (
          <CommandEmpty>No results found.</CommandEmpty>
        )}
        {!data && selectedOption !== CommandMenuOptions.NO_OPTION_SELECTED && (
          <CommandLoading className="justify-center m-2">
            <div className="flex items-center gap-1">
              {loading ? (
                <Fragment>
                  <Loader className="size-4 animate-spin" />
                  <span>
                    Searching for{' '}
                    {selectedOption === CommandMenuOptions.USER_PROFILE
                      ? 'users'
                      : 'packages'}
                    ...
                  </span>
                </Fragment>
              ) : (
                <Fragment>
                  <ScanSearch className="size-4" />
                  <span>
                    Start typing to search for{' '}
                    {selectedOption === CommandMenuOptions.USER_PROFILE
                      ? 'users'
                      : 'packages'}
                    ...
                  </span>
                </Fragment>
              )}
            </div>
          </CommandLoading>
        )}
        {data && (
          <CommandGroup heading="Packages">
            {data.map(pkg => (
              <CommandItem
                key={`command-item-${pkg.pkgname}-${pkg.pkgbase}-${pkg.repository}-${pkg.march}`}
                onSelect={() => packageSelectCallback(pkg)}
                value={`${pkg.pkgname} ${pkg.pkgbase} ${pkg.repository} ${pkg.march}`}
              >
                Package: {pkg.pkgname} ({pkg.pkgbase}) in {pkg.repository} (
                {pkg.march})
              </CommandItem>
            ))}
          </CommandGroup>
        )}
        {searchedUser && (
          <CommandGroup heading="Users">
            <CommandItem
              key={`command-item-users-${searchedUser.username}`}
              onSelect={() => userProfileSelectCallback(searchedUser.username)}
              value={searchedUser.username}
            >
              <Avatar className="size-10 rounded-lg bg-muted">
                <AvatarImage
                  alt={searchedUser.username}
                  {...(searchedUser.profile_picture_url
                    ? {src: searchedUser.profile_picture_url}
                    : {})}
                />
                <AvatarFallback className="rounded-lg">
                  {searchedUser.username
                    .split(' ')
                    .map(x => x.at(0))
                    .join('')
                    .toUpperCase()}
                </AvatarFallback>
              </Avatar>
              User: @{searchedUser.username}{' '}
              {searchedUser.display_name
                ? `(${searchedUser.display_name})`
                : ''}
            </CommandItem>
          </CommandGroup>
        )}
        <CommandSeparator />
        <CommandGroup heading="Suggestions">
          <CommandItem
            onSelect={() =>
              optionSelectCallback(CommandMenuOptions.REBUILD_PACKAGE)
            }
          >
            <RotateCcw />
            Rebuild Package
          </CommandItem>
          <CommandItem
            onSelect={() =>
              optionSelectCallback(CommandMenuOptions.GET_PACKAGE_LOGS)
            }
          >
            <SquareTerminal />
            Get Package Logs
          </CommandItem>
          <CommandItem
            onSelect={() =>
              optionSelectCallback(CommandMenuOptions.USER_PROFILE)
            }
          >
            <User />
            User Profile
          </CommandItem>
        </CommandGroup>
      </CommandList>
    </CommandDialog>
  );
}
