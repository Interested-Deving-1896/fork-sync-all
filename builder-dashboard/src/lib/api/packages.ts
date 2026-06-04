import stripAnsi from 'strip-ansi';

import {
  APIVersion,
  BasePackage,
  BasePackageSchema,
  BasePackageWithIDList,
  BasePackageWithIDListSchema,
  BulkRebuildPackagesResponse,
  BulkRebuildPackagesResponseSchema,
  ListPackageResponse,
  ListPackageResponseSchema,
  ListPackagesQuery,
  PackageList,
  PackageListSchema,
  PackageMArch,
  RebuildPackageList,
  RebuildPackageListSchema,
  RebuildPackageResponse,
  RebuildPackageResponseSchema,
  ResponseType,
  SearchPackagesQuery,
  UserScope,
} from '@/lib/typings';

import {BaseClient} from './base';
import {buildQuery, parseOrThrow, requireScopes} from './helpers';

const EMPTY_PACKAGE_LIST: ListPackageResponse = {
  packages: [],
  total_items: 0,
  total_pages: 0,
};

export class PackagesClient {
  constructor(private base: BaseClient) {}

  public async bulkRebuildPackages(
    packages: BasePackageWithIDList,
    clientHeaders = new Headers()
  ) {
    const parsed = parseOrThrow(
      BasePackageWithIDListSchema,
      packages,
      'package list request'
    );

    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(
      scopes,
      [UserScope.READ, UserScope.WRITE],
      'rebuild packages'
    );

    const response = await this.base
      ._fetcher<BulkRebuildPackagesResponse>({
        clientHeaders,
        endpoint: 'bulk-rebuild',
        init: {body: JSON.stringify(parsed), method: 'PUT'},
      })
      .catch(() => []);
    return parseOrThrow(
      BulkRebuildPackagesResponseSchema,
      response,
      'bulk rebuild packages response'
    );
  }

  public async getPackageLog(
    pkg: string,
    march: PackageMArch,
    strip = false,
    clientHeaders = new Headers()
  ): Promise<string> {
    return this.base
      ._fetcher<string>({
        clientHeaders,
        endpoint: `logs/${march}/${pkg}.log`,
        init: {cache: 'no-store'},
        mode: ResponseType.TEXT,
      })
      .then(text => (strip ? stripAnsi(text) : text))
      .catch(() => '');
  }

  public async listPackages(
    query?: ListPackagesQuery,
    clientHeaders = new Headers()
  ) {
    const search = buildQuery({
      current_page: query?.current_page,
      march_filter: query?.march_filter,
      page_size: query?.page_size,
      repo_filter: query?.repo_filter,
      status_filter: query?.status_filter,
    });

    const response = await this.base
      ._fetcher<ListPackageResponse>({
        clientHeaders,
        endpoint: `packages?${search}`,
        version: APIVersion.V3,
      })
      .catch(() => EMPTY_PACKAGE_LIST);
    return parseOrThrow(
      ListPackageResponseSchema,
      response,
      'package list response'
    );
  }

  public async listRebuildPackages(clientHeaders = new Headers()) {
    const response = await this.base
      ._fetcher<RebuildPackageList>({
        clientHeaders,
        endpoint: 'rebuild-status',
        version: APIVersion.V2,
      })
      .catch(() => []);
    return parseOrThrow(
      RebuildPackageListSchema,
      response,
      'package list response'
    );
  }

  public async rebuildPackage(pkg: BasePackage, clientHeaders = new Headers()) {
    const parsed = parseOrThrow(BasePackageSchema, pkg, 'package request');

    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(
      scopes,
      [UserScope.READ, UserScope.WRITE],
      'rebuild packages'
    );

    const response = await this.base
      ._fetcher<RebuildPackageResponse>({
        clientHeaders,
        endpoint: `rebuild/${parsed.march}/${parsed.repository}/${parsed.pkgbase}`,
        init: {method: 'PUT'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      RebuildPackageResponseSchema,
      response,
      'rebuild package response'
    );
  }

  public async searchPackages(
    query: SearchPackagesQuery,
    clientHeaders = new Headers()
  ) {
    const search = buildQuery({
      march_filter: query.march_filter,
      repo_filter: query.repo_filter,
      search: query.search,
      status_filter: query.status_filter,
    });

    const response = await this.base
      ._fetcher<PackageList>({
        clientHeaders,
        endpoint: `packages-search?${search}`,
      })
      .catch(() => []);
    return parseOrThrow(PackageListSchema, response, 'package list response');
  }
}
