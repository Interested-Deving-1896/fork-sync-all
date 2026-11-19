'use server';

import {headers} from 'next/headers';
import {redirect} from 'next/navigation';

import {getSession} from '@/app/actions/session';
import {
  BasePackageWithIDList,
  ListPackagesQuery,
  PackageMArch,
  PackageRepo,
  SearchPackagesQuery,
} from '@/lib/typings';

export async function bulkRebuildPackages(packages: BasePackageWithIDList) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const response = await cachyBuilderClient.packages.bulkRebuildPackages(
      packages,
      await headers()
    );
    return response;
  } catch (error) {
    return {
      error: `Failed to bulk rebuild packages: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function getPackageLog(
  pkg: string,
  march: PackageMArch,
  strip = false
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const log = await cachyBuilderClient.packages.getPackageLog(
      pkg,
      march,
      strip,
      await headers()
    );
    return log;
  } catch (error) {
    return {
      error: `Failed to get package log: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function listPackages(query?: ListPackagesQuery) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const packages = await cachyBuilderClient.packages.listPackages(
      query,
      await headers()
    );
    return packages;
  } catch (error) {
    return {
      error: `Failed to list packages: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function listRebuildPackages() {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const packages = await cachyBuilderClient.packages.listRebuildPackages(
      await headers()
    );
    return packages;
  } catch (error) {
    return {
      error: `Failed to list packages: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function rebuildPackage(
  pkgbase: string,
  march: PackageMArch,
  repository: PackageRepo
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const response = await cachyBuilderClient.packages.rebuildPackage(
      {march, pkgbase, repository},
      await headers()
    );
    return response;
  } catch (error) {
    return {
      error: `Failed to rebuild package: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function searchPackages(query: SearchPackagesQuery) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const packages = await cachyBuilderClient.packages.searchPackages(
      query,
      await headers()
    );
    return packages;
  } catch (error) {
    return {
      error: `Failed to list packages: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}
