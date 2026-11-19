import {
  AddMaintainerRequest,
  AddMaintainerRequestSchema,
  AddMaintainerResponse,
  AddMaintainerResponseSchema,
  MaintainerListResponse,
  MaintainerListResponseSchema,
  RevokeMaintainerResponse,
  RevokeMaintainerResponseSchema,
  UserScope,
} from '@/lib/typings';

import {BaseClient} from './base';
import {buildQuery, parseOrThrow, requireScopes} from './helpers';

const EMPTY_MAINTAINER_LIST: MaintainerListResponse = {
  maintainers: [],
  total_items: 0,
  total_pages: 0,
};

export class MaintainersClient {
  constructor(private base: BaseClient) {}

  public async addMaintainer(
    request: AddMaintainerRequest,
    clientHeaders = new Headers()
  ) {
    const parsed = parseOrThrow(
      AddMaintainerRequestSchema,
      request,
      'add maintainer request'
    );

    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(scopes, [UserScope.ADMIN], 'add maintainers');

    const response = await this.base
      ._fetcher<AddMaintainerResponse>({
        clientHeaders,
        endpoint: 'admin/maintainers',
        init: {body: JSON.stringify(parsed), method: 'POST'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      AddMaintainerResponseSchema,
      response,
      'add maintainer response'
    );
  }

  public async getMaintainers(
    currentPage = 1,
    pageSize = 200,
    clientHeaders = new Headers()
  ) {
    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(scopes, [UserScope.ADMIN], 'view maintainers');

    const search = buildQuery({current_page: currentPage, page_size: pageSize});

    const response = await this.base
      ._fetcher<MaintainerListResponse>({
        clientHeaders,
        endpoint: `admin/maintainers?${search}`,
      })
      .catch(() => EMPTY_MAINTAINER_LIST);
    return parseOrThrow(
      MaintainerListResponseSchema,
      response,
      'maintainers response'
    );
  }

  public async revokeMaintainer(id: string, clientHeaders = new Headers()) {
    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(scopes, [UserScope.ADMIN], 'revoke maintainers');

    const response = await this.base
      ._fetcher<RevokeMaintainerResponse>({
        clientHeaders,
        endpoint: `admin/maintainers/${id}`,
        init: {method: 'DELETE'},
      })
      .catch(() => ({}));
    return parseOrThrow(
      RevokeMaintainerResponseSchema,
      response,
      'revoke maintainer response'
    );
  }
}
