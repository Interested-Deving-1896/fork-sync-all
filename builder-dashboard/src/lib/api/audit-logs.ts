import {APIVersion, AuditLogList, AuditLogListSchema} from '@/lib/typings';

import {BaseClient} from './base';
import {emptyOn404, parseOrThrow} from './helpers';

export class AuditLogsClient {
  constructor(private base: BaseClient) {}

  public async getAuditLogs(clientHeaders = new Headers()) {
    const response = await emptyOn404<AuditLogList>(
      () =>
        this.base._fetcher<AuditLogList>({
          clientHeaders,
          endpoint: 'audit-logs',
          version: APIVersion.V2,
        }),
      []
    );
    return parseOrThrow(AuditLogListSchema, response, 'audit log response');
  }
}
