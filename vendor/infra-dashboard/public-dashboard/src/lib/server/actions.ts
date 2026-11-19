// SPA mode: all data fetching is client-side via fetch() against VITE_ENDPOINT_URL.
// No server functions, no Redis cache — caching is handled by React Query.
import {z} from 'zod';

import fetcher from '@/lib/fetcher';
import {
  type PackageDetailFilesResponse,
  PackageDetailFilesResponseSchema,
  type PackageDetailsPathParams,
  type PackageDetailsResponse,
  PackageDetailsResponseSchema,
  type PackageSearchResponse,
  PackageSearchResponseSchema,
  type PackagesSearchQueryParams,
  type SplitPackagesQueryParams,
  SplitPackagesResponseSchema,
  type SplitPackagesResponse,
} from '@/lib/types';

// In SPA mode headers are not forwarded — use empty headers
const clientHeaders = new Headers();

export async function getPackageDetails(
  data: PackageDetailsPathParams
): Promise<PackageDetailsResponse> {
  const {arch, pkgname, repo} = data;
  return fetcher(`/v1/package/${repo}/${arch}/${pkgname}`, clientHeaders, PackageDetailsResponseSchema);
}

export async function getPackageFiles(
  data: PackageDetailsPathParams
): Promise<PackageDetailFilesResponse> {
  const {arch, pkgname, repo} = data;
  return fetcher(`/v1/package/${repo}/${arch}/${pkgname}/files`, clientHeaders, PackageDetailFilesResponseSchema);
}

export async function getSplitPackages(
  data: SplitPackagesQueryParams
): Promise<SplitPackagesResponse> {
  const {pkgbase, repo} = data;
  return fetcher(`/v1/split/${repo}/${pkgbase}`, clientHeaders, SplitPackagesResponseSchema);
}

export async function searchPackages(
  data: PackagesSearchQueryParams,
  signal?: AbortSignal
): Promise<PackageSearchResponse> {
  const query = new URLSearchParams();
  if (data.search) query.append('search', data.search);
  if (data.repo) query.append('repo', data.repo);
  if (data.arch) query.append('arch', data.arch);
  if (data.current_page) query.append('current_page', String(data.current_page));
  if (data.page_size) query.append('page_size', String(data.page_size));
  const qs = query.toString();
  return fetcher(
    `/v1/packages-search${qs ? `?${qs}` : ''}`,
    clientHeaders,
    PackageSearchResponseSchema,
    {method: 'GET', signal}
  );
}

const SourceUrlInputSchema = z.object({
  pkg_base: z.string().nullable(),
  pkg_name: z.string(),
  pkg_version: z.string(),
  repo_name: z.string(),
});
type SourceUrlInput = z.infer<typeof SourceUrlInputSchema>;

export async function getSourceUrl(data: SourceUrlInput): Promise<string> {
  // Source URL derivation is pure logic — no server needed
  const {getSourceUrl: computeSourceUrl} = await import('@/lib/server/source-url');
  return computeSourceUrl(data);
}

export {computeMirrorsData as getMirrorsData} from '@/lib/mirrors-client';
