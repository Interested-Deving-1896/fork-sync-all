import {ReadonlyHeaders} from 'next/dist/server/web/spec-extension/adapters/headers';
import stripAnsi from 'strip-ansi';

import {APIVersion, ResponseType, UserScope} from '@/lib/typings';

export interface FetchOptions {
  authToken?: string;
  baseURL?: string;
  clientHeaders: Headers | ReadonlyHeaders;
  endpoint: string;
  init?: RequestInit;
  mode?: ResponseType;
  version?: APIVersion;
}

export interface ServerToken {
  description: string;
  name: string;
  scopes: UserScope[];
  token: string;
  url: string;
}

export class HttpError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body = ''
  ) {
    super(`HTTP ${status} ${statusText}${body ? `: ${body}` : ''}`);
    this.name = 'HttpError';
  }
}

export function isAccessibleToken(token: ServerToken): boolean {
  return token.token !== '' && token.scopes.length > 0;
}

// Server list is driven by environment variables at build time.
// Set BUILDER_SERVERS as a JSON array, e.g.:
//   [{"name":"Primary","description":"Primary Builder","url":"https://builder-api.example.com/api","default":true}]
// Falls back to localhost for local development.
function parseServers() {
  try {
    const raw =
      process.env.BUILDER_SERVERS ??
      process.env.NEXT_PUBLIC_BUILDER_SERVERS;
    if (raw) return JSON.parse(raw) as typeof DEFAULT_SERVERS;
  } catch {
    // fall through to default
  }
  return DEFAULT_SERVERS;
}

const DEFAULT_SERVERS = [
  {
    default: true,
    description: 'Primary Builder',
    name: 'Builder Primary',
    url: process.env.BUILDER_API_URL_PRIMARY ?? 'http://localhost:8080/api',
  },
  {
    default: false,
    description: 'Secondary Builder',
    name: 'Builder Secondary',
    url: process.env.BUILDER_API_URL_SECONDARY ?? 'http://localhost:8081/api',
  },
];

export const SERVERS = parseServers();

export class BaseClient {
  public static readonly servers = SERVERS;

  public baseURL: string;
  public serverIndex: number;
  public token: string;
  public tokens: ServerToken[];

  constructor(
    serverIndex: number,
    tokens: ServerToken[] = BaseClient.servers.map(s => ({
      description: s.description,
      name: s.name,
      scopes: [] as UserScope[],
      token: '',
      url: s.url,
    }))
  ) {
    if (serverIndex === -1 || serverIndex >= BaseClient.servers.length) {
      throw new Error(`Invalid Server Index: ${serverIndex}`);
    }
    this.serverIndex = serverIndex;
    this.baseURL = BaseClient.servers[this.serverIndex].url;
    this.token = tokens[serverIndex].token;
    this.tokens = tokens;
  }

  public async _fetcher<T>(opts: FetchOptions): Promise<T> {
    const {
      authToken = this.token,
      baseURL = this.baseURL,
      clientHeaders,
      endpoint,
      init,
      mode = ResponseType.JSON,
      version = APIVersion.V1,
    } = opts;
    return fetch(`${baseURL}/${version}/${endpoint}`, {
      ...init,
      headers: {
        ...(authToken ? {Authorization: `Bearer ${authToken}`} : {}),
        'Content-Type': 'application/json',
        'User-Agent':
          clientHeaders.get('User-Agent') ??
          'BuilderDashboardProxyServer/1.0.0',
        'X-Forwarded-For':
          clientHeaders.get('CF-Connecting-IP') ??
          clientHeaders.get('X-Forwarded-For') ??
          '',
        ...init?.headers,
      },
    }).then(res => this._processResponse<T>(res, mode));
  }

  public async _processResponse<T>(
    response: Response,
    mode: ResponseType
  ): Promise<T> {
    if (!response.ok) {
      let body = '';
      try {
        body = await response.text();
      } catch {
        // ignore read errors
      }
      throw new HttpError(
        response.status,
        response.statusText,
        body ? stripAnsi(body) : ''
      );
    }
    switch (mode) {
      case ResponseType.JSON:
        return response.json() as Promise<T>;
      case ResponseType.RAW:
        return response.arrayBuffer() as Promise<T>;
      case ResponseType.TEXT:
        return response.text() as Promise<T>;
    }
  }
}
