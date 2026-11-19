'use server';

import {headers} from 'next/headers';
import {redirect} from 'next/navigation';

import {getSession} from '@/app/actions/session';
import {ListRepoActionsQuery, ParsedRepoAction} from '@/lib/typings';

export async function listRepoActions(query?: ListRepoActionsQuery) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const actions = await cachyBuilderClient.repoActions
      .listRepoActions(query, await headers())
      .then(response => {
        return {
          ...response,
          actions: response.actions.map(action => {
            const parsedPackages = action.packages
              .split(',')
              .map(pkg => ({...action, packages: pkg.trim()}));
            return {
              ...action,
              packages:
                parsedPackages.length > 1
                  ? `${parsedPackages.length} packages`
                  : parsedPackages.shift()!.packages,
              parsedPackages,
            } as ParsedRepoAction;
          }),
        };
      });
    return actions;
  } catch (error) {
    return {
      error: `Failed to list repo actions: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}
