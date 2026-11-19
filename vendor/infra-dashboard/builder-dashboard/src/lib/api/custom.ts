import {
  CancelSubmissionResponse,
  CancelSubmissionResponseSchema,
  CustomPackageResponse,
  CustomPackageResponseSchema,
  CustomRepoResponse,
  CustomRepoResponseSchema,
  PackageSubmissionResponse,
  PackageSubmissionResponseSchema,
  SubmissionActionResponse,
  SubmissionActionResponseSchema,
  SubmitPackageRequest,
  SubmitPackageRequestSchema,
  UserScope,
} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

import {BaseClient} from './base';
import {buildQuery, parseOrThrow, requireScopes} from './helpers';

export class CustomClient {
  constructor(private base: BaseClient) {}

  public async approveSubmission(
    id: string,
    note?: string,
    clientHeaders = new Headers()
  ) {
    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(scopes, [UserScope.ADMIN], 'approve submissions');

    const response = await this.base
      ._fetcher<SubmissionActionResponse>({
        clientHeaders,
        endpoint: `package-submissions/${id}/approve`,
        init: {body: JSON.stringify(note ? {note} : {}), method: 'PUT'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      SubmissionActionResponseSchema,
      response,
      'approve submission response'
    );
  }

  public async cancelSubmission(id: string, clientHeaders = new Headers()) {
    const response = await this.base
      ._fetcher<CancelSubmissionResponse>({
        clientHeaders,
        endpoint: `package-submissions/${id}/cancel`,
        init: {method: 'PUT'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      CancelSubmissionResponseSchema,
      response,
      'cancel submission response'
    );
  }

  public async getCustomPackages(
    currentPage = 1,
    pageSize = 200,
    clientHeaders = new Headers()
  ) {
    const search = buildQuery({current_page: currentPage, page_size: pageSize});
    const response = await this.base
      ._fetcher<CustomPackageResponse>({
        clientHeaders,
        endpoint: `custom-packages?${search}`,
      })
      .catch(() => ({custom_packages: [], total_items: 0, total_pages: 0}));
    return parseOrThrow(
      CustomPackageResponseSchema,
      response,
      'custom packages response'
    );
  }

  public async getCustomRepos(
    currentPage = 1,
    pageSize = 200,
    clientHeaders = new Headers()
  ) {
    const search = buildQuery({current_page: currentPage, page_size: pageSize});
    const response = await this.base
      ._fetcher<CustomRepoResponse>({
        clientHeaders,
        endpoint: `custom-repos?${search}`,
      })
      .catch(() => ({repos: [], total_items: 0, total_pages: 0}));
    return parseOrThrow(
      CustomRepoResponseSchema,
      response,
      'custom repos response'
    );
  }

  public async getPackageSubmissions(
    status?: string,
    currentPage = 1,
    pageSize = 200,
    clientHeaders = new Headers()
  ) {
    const search = buildQuery({
      current_page: currentPage,
      page_size: pageSize,
      status,
    });
    const response = await this.base
      ._fetcher<PackageSubmissionResponse>({
        clientHeaders,
        endpoint: `package-submissions?${search}`,
      })
      .catch(() => ({submissions: [], total_items: 0, total_pages: 0}));
    return parseOrThrow(
      PackageSubmissionResponseSchema,
      response,
      'package submissions response'
    );
  }

  public async queueSubmission(id: string, clientHeaders = new Headers()) {
    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(scopes, [UserScope.ADMIN], 'queue submissions');

    const response = await this.base
      ._fetcher<SubmissionActionResponse>({
        clientHeaders,
        endpoint: `package-submissions/${id}/queue`,
        init: {method: 'PUT'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      SubmissionActionResponseSchema,
      response,
      'queue submission response'
    );
  }

  public async rejectSubmission(
    id: string,
    note?: string,
    clientHeaders = new Headers()
  ) {
    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(scopes, [UserScope.ADMIN], 'reject submissions');

    const response = await this.base
      ._fetcher<SubmissionActionResponse>({
        clientHeaders,
        endpoint: `package-submissions/${id}/reject`,
        init: {body: JSON.stringify(note ? {note} : {}), method: 'PUT'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      SubmissionActionResponseSchema,
      response,
      'reject submission response'
    );
  }

  public async submitPackage(
    request: SubmitPackageRequest,
    clientHeaders = new Headers()
  ) {
    const parsed = parseOrThrow(
      SubmitPackageRequestSchema,
      request,
      'submit package request'
    );

    const {scopes} = this.base.tokens[this.base.serverIndex];
    if (
      !checkScopes(scopes, [UserScope.PACKAGER]) &&
      !checkScopes(scopes, [UserScope.ADMIN])
    ) {
      throw new Error('You are not authorized to submit packages');
    }

    const response = await this.base
      ._fetcher<SubmissionActionResponse>({
        clientHeaders,
        endpoint: 'package-submissions',
        init: {body: JSON.stringify(parsed), method: 'POST'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      SubmissionActionResponseSchema,
      response,
      'submit package response'
    );
  }
}
