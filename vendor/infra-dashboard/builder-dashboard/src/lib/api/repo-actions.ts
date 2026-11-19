import {
  ListRepoActionsQuery,
  RepoActionsResponse,
  RepoActionsResponseSchema,
} from '@/lib/typings';

import {BaseClient} from './base';
import {buildQuery, parseOrThrow} from './helpers';

const EMPTY_REPO_ACTIONS: RepoActionsResponse = {
  actions: [],
  total_items: 0,
  total_pages: 0,
};

export class RepoActionsClient {
  constructor(private base: BaseClient) {}

  public async listRepoActions(
    query?: ListRepoActionsQuery,
    clientHeaders = new Headers()
  ) {
    const search = buildQuery({
      current_page: query?.current_page,
      march: query?.march,
      page_size: query?.page_size,
      repo: query?.repo,
    });

    const response = await this.base
      ._fetcher<RepoActionsResponse>({
        clientHeaders,
        endpoint: `repo-actions?${search}`,
      })
      .catch(() => EMPTY_REPO_ACTIONS);
    return parseOrThrow(
      RepoActionsResponseSchema,
      response,
      'repo actions response'
    );
  }
}
