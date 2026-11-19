'use server';

import {headers} from 'next/headers';
import {redirect} from 'next/navigation';

import {getSession} from '@/app/actions/session';
import {
  type ActionError,
  AddMaintainerRequest,
  type CustomPackage,
  type CustomRepo,
  isActionError,
  type MaintainerPolicy,
  type PackageSubmission,
  SubmitPackageRequest,
} from '@/lib/typings';

const DEFAULT_PAGE_SIZE = 200;
const MAX_LOOKUP_PAGES = 50;

interface PageResult<T> {
  items: T[];
  totalPages: number;
}

export async function addMaintainer(request: AddMaintainerRequest) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.maintainers.addMaintainer(
      request,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to add maintainer: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function approveSubmission(id: string, note?: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.approveSubmission(
      id,
      note,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to approve submission: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function cancelSubmission(id: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.cancelSubmission(
      id,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to cancel submission: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function findMaintainersByUsername(
  username: string
): Promise<ActionError | MaintainerPolicy[]> {
  const matches: MaintainerPolicy[] = [];
  let totalPages = 1;
  for (let page = 1; page <= Math.min(totalPages, MAX_LOOKUP_PAGES); page++) {
    const r = await getMaintainers(page, DEFAULT_PAGE_SIZE);
    if (isActionError(r)) return r;
    totalPages = r.total_pages;
    for (const m of r.maintainers) {
      if (m.username === username) matches.push(m);
    }
  }
  return matches;
}

export async function findPackageBy(predicate: {
  march: string;
  pkgname: string;
  repository: string;
}): Promise<ActionError | CustomPackage | null> {
  return findInPages<CustomPackage>(
    async (page, size) => {
      const r = await getCustomPackages(page, size);
      if (isActionError(r)) return r;
      return {items: r.custom_packages, totalPages: r.total_pages};
    },
    p =>
      p.repository === predicate.repository &&
      p.march === predicate.march &&
      p.pkgname === predicate.pkgname
  );
}

export async function findRepoById(
  id: string
): Promise<ActionError | CustomRepo | null> {
  return findInPages<CustomRepo>(
    async (page, size) => {
      const r = await getCustomRepos(page, size);
      if (isActionError(r)) return r;
      return {items: r.repos, totalPages: r.total_pages};
    },
    repo => repo.id === id
  );
}

export async function findSubmissionById(
  id: string
): Promise<ActionError | null | PackageSubmission> {
  return findInPages<PackageSubmission>(
    async (page, size) => {
      const r = await getPackageSubmissions(undefined, page, size);
      if (isActionError(r)) return r;
      return {items: r.submissions, totalPages: r.total_pages};
    },
    s => s.id === id
  );
}

export async function getCustomPackages(
  currentPage = 1,
  pageSize: number = DEFAULT_PAGE_SIZE
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.getCustomPackages(
      currentPage,
      pageSize,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to get custom packages: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function getCustomRepos(
  currentPage = 1,
  pageSize: number = DEFAULT_PAGE_SIZE
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.getCustomRepos(
      currentPage,
      pageSize,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to get custom repos: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function getMaintainers(
  currentPage = 1,
  pageSize: number = DEFAULT_PAGE_SIZE
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.maintainers.getMaintainers(
      currentPage,
      pageSize,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to get maintainers: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function getPackageSubmissions(
  status?: string,
  currentPage = 1,
  pageSize: number = DEFAULT_PAGE_SIZE
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.getPackageSubmissions(
      status,
      currentPage,
      pageSize,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to get package submissions: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function queueSubmission(id: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.queueSubmission(id, await headers());
  } catch (error) {
    return {
      error: `Failed to queue submission: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function rejectSubmission(id: string, note?: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.rejectSubmission(
      id,
      note,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to reject submission: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function revokeMaintainer(id: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.maintainers.revokeMaintainer(
      id,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to revoke maintainer: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function submitPackage(request: SubmitPackageRequest) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    return await cachyBuilderClient.custom.submitPackage(
      request,
      await headers()
    );
  } catch (error) {
    return {
      error: `Failed to submit package: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

async function findInPages<T>(
  fetchPage: (
    page: number,
    pageSize: number
  ) => Promise<ActionError | PageResult<T>>,
  predicate: (item: T) => boolean,
  pageSize: number = DEFAULT_PAGE_SIZE,
  maxPages: number = MAX_LOOKUP_PAGES
): Promise<ActionError | null | T> {
  let totalPages = 1;
  for (let page = 1; page <= Math.min(totalPages, maxPages); page++) {
    const result = await fetchPage(page, pageSize);
    if (isActionError(result)) return result;
    totalPages = result.totalPages;
    const match = result.items.find(predicate);
    if (match) return match;
  }
  return null;
}
