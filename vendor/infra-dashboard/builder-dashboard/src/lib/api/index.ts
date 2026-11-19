import {
  LoginRequest,
  LoginRequestSchema,
  LoginResponse,
  LoginResponseSchema,
  UserScope,
  userScopeArray,
} from '@/lib/typings';

import {AuditLogsClient} from './audit-logs';
import {BaseClient, ServerToken} from './base';
import {CustomClient} from './custom';
import {multiServerCall, MultiServerCallResult, parseOrThrow} from './helpers';
import {MaintainersClient} from './maintainers';
import {PackagesClient} from './packages';
import {RepoActionsClient} from './repo-actions';
import {StatsClient} from './stats';
import {UsersClient} from './users';

export type {ServerToken};

export default class CachyBuilderClient {
  public static readonly servers = BaseClient.servers;

  public readonly auditLogs: AuditLogsClient;

  public readonly custom: CustomClient;
  public readonly maintainers: MaintainersClient;
  public readonly packages: PackagesClient;
  public readonly repoActions: RepoActionsClient;
  public readonly stats: StatsClient;
  public readonly users: UsersClient;
  public get apiTokens() {
    return this.base.tokens;
  }

  public get baseURL() {
    return this.base.baseURL;
  }

  public get serverIdx() {
    return this.base.serverIndex;
  }

  private base: BaseClient;

  constructor(serverIndex: number, tokens?: ServerToken[]) {
    this.base = new BaseClient(serverIndex, tokens);
    this.packages = new PackagesClient(this.base);
    this.stats = new StatsClient(this.base);
    this.users = new UsersClient(this.base);
    this.custom = new CustomClient(this.base);
    this.maintainers = new MaintainersClient(this.base);
    this.auditLogs = new AuditLogsClient(this.base);
    this.repoActions = new RepoActionsClient(this.base);
  }

  public async login(
    loginRequest: LoginRequest,
    clientHeaders = new Headers(),
    allowInvalid = false
  ) {
    const requestData = parseOrThrow(
      LoginRequestSchema,
      loginRequest,
      'login request'
    );

    const {errors, results} = await multiServerCall<LoginResponse>({
      allowInvalid,
      base: this.base,
      clientHeaders,
      label: 'User Login',
      request: {
        endpoint: 'login',
        init: {body: JSON.stringify(requestData), method: 'POST'},
      },
      schema: LoginResponseSchema,
      targets: CachyBuilderClient.servers.map(s => ({
        name: s.name,
        url: s.url,
      })),
    });

    this.base.tokens = results.map((r, i) => ({
      description: CachyBuilderClient.servers[i].description,
      name: CachyBuilderClient.servers[i].name,
      scopes: r.ok ? [UserScope.READ] : [],
      token: r.ok ? r.data.token : '',
      url: CachyBuilderClient.servers[i].url,
    }));

    this.base.token = this.base.tokens[this.base.serverIndex].token;

    if (!this.base.token) {
      this.base.serverIndex = results.findIndex(r => r.ok);
      if (this.base.serverIndex === -1) {
        throw new Error('No valid server found with a valid token.');
      }
      this.base.baseURL = CachyBuilderClient.servers[this.base.serverIndex].url;
      this.base.token = this.base.tokens[this.base.serverIndex].token;
    }

    return {
      errors,
      validServers: CachyBuilderClient.servers.filter((_, i) => results[i].ok),
    };
  }

  public async syncLoggedInUserScopes(
    allowInvalid = false,
    clientHeaders = new Headers(),
    serverName?: string
  ) {
    const validServers = this.base.tokens.filter(
      s => !!s.token && (serverName === undefined || s.name === serverName)
    );

    if (validServers.length === 0) {
      throw new Error('No valid servers to get profile scopes on');
    }

    const isFailure = (r: MultiServerCallResult<UserScope[]>) =>
      !r.ok || r.data.length === 0;

    const {errors, results} = await multiServerCall<UserScope[]>({
      allowInvalid,
      base: this.base,
      clientHeaders,
      isFailure,
      label: 'Get User Scopes',
      request: {endpoint: 'user-profile/scopes'},
      retryOnAuth: true,
      schema: userScopeArray,
      targets: validServers,
    });

    const outcomes = validServers.map((server, i) => ({
      failed: isFailure(results[i]),
      result: results[i],
      server,
    }));

    const unreachable = outcomes.filter(o => o.failed).map(o => o.server.name);

    const scopesByName = new Map(
      outcomes.flatMap(({failed, result, server}) =>
        !failed && result.ok ? [[server.name, result.data] as const] : []
      )
    );

    this.base.tokens = this.base.tokens.map(token => {
      const scopes = scopesByName.get(token.name);
      return scopes ? {...token, scopes} : token;
    });

    return {
      errors,
      tokens: this.base.tokens,
      unreachable,
    };
  }

  public updateServer(server: string): void {
    const index = CachyBuilderClient.servers.findIndex(s => s.name === server);
    if (index === -1) {
      throw new Error(`Server not found: ${server}`);
    }
    this.base.serverIndex = index;
    this.base.baseURL = CachyBuilderClient.servers[this.base.serverIndex].url;
    this.base.token = this.base.tokens[index].token;
  }
}
