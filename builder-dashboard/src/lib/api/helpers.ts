import {ReadonlyHeaders} from 'next/dist/server/web/spec-extension/adapters/headers';
import {z} from 'zod/v4';

import {APIVersion, UserScope} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

import {BaseClient, HttpError} from './base';

/**
 * Fallback policy for read endpoints:
 *  - HTTP 404 is treated as "empty" everywhere: the resource simply doesn't exist
 *    yet while the endpoint itself is correct. Use `emptyOn404` for single-resource
 *    / stats reads so a 404 yields the typed empty value instead of throwing.
 *  - Paginated / list-style reads degrade on any error (network / 5xx / 404) to a
 *    typed empty value.
 *  - Single-resource reads that have no valid empty representation propagate errors.
 *  - Mutations keep their own per-call fallback and rely on `parseOrThrow` to reject
 *    unexpected payloads.
 */

export type MultiServerCallResult<T> =
  | {data: T; ok: true}
  | {error: Error; ok: false; reason: 'fetch'; status?: number}
  | {error: z.ZodError<T>; ok: false; raw: unknown; reason: 'parse'};

export interface MultiServerTarget {
  name: string;
  token?: string;
  url: string;
}

const sleep = (ms: number) => new Promise<void>(r => setTimeout(r, ms));

const isAuthError = (e: unknown): e is HttpError =>
  e instanceof HttpError && (e.status === 401 || e.status === 403);

export function buildQuery(
  params: Record<string, number | string | string[] | undefined>
): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) {
      if (value.length) search.set(key, value.join(','));
    } else {
      search.set(key, String(value));
    }
  }
  return search.toString();
}

export async function emptyOn404<T>(
  fn: () => Promise<T>,
  empty: T
): Promise<T> {
  try {
    return await fn();
  } catch (e) {
    if (e instanceof HttpError && e.status === 404) {
      return empty;
    }
    throw e;
  }
}

/** Produces the per-target line that appears in the aggregated `errors` string. */
export function formatTargetError<T>(
  result: MultiServerCallResult<T>,
  name: string
): null | string {
  if (result.ok) return null;
  const detail =
    result.reason === 'fetch'
      ? result.error.message
      : result.error.issues.map(i => i.message).join(', ');
  return `Server: ${name} ${detail}`;
}

/**
 * Fans a single request out to multiple servers, parses each response, aggregates
 * per-server error messages, and applies the `allowInvalid` warn/throw policy.
 * Callers keep their own side effects (token assignment, scope merging, picking a
 * fallback server) since those differ per call.
 */
export async function multiServerCall<T>(opts: {
  allowInvalid: boolean;
  base: BaseClient;
  clientHeaders: Headers | ReadonlyHeaders;
  isFailure?: (result: MultiServerCallResult<T>) => boolean;
  label: string;
  request: {endpoint: string; init?: RequestInit; version?: APIVersion};
  retryOnAuth?: boolean;
  schema: z.ZodType<T>;
  targets: MultiServerTarget[];
}): Promise<{
  errors: string;
  failedCount: number;
  results: MultiServerCallResult<T>[];
}> {
  const {
    allowInvalid,
    base,
    clientHeaders,
    isFailure = r => !r.ok,
    label,
    request,
    retryOnAuth = false,
    schema,
    targets,
  } = opts;

  const results = await Promise.all(
    targets.map(target =>
      runTarget(base, target, clientHeaders, request, schema, retryOnAuth)
    )
  );

  const errors = results
    .map((r, i) => formatTargetError(r, targets[i].name))
    .filter((line): line is string => line !== null)
    .join('\n');
  const failedCount = results.filter(isFailure).length;

  if (failedCount > 0) {
    if (allowInvalid && failedCount !== targets.length) {
      console.warn(
        `[${label}] Some servers failed to respond correctly, but continuing due to allowInvalid flag.\n${errors}`
      );
    } else {
      throw new Error(`Invalid response from server(s):\n${errors}`);
    }
  }

  return {errors, failedCount, results};
}

/**
 * Validates `value` against `schema`, throwing a uniform error on failure.
 * `label` should carry the full noun, e.g. "package list response" or
 * "add maintainer request".
 */
export function parseOrThrow<T>(
  schema: z.ZodType<T>,
  value: unknown,
  label: string
): T {
  const result = schema.safeParse(value);
  if (!result.success) {
    throw new Error(
      `Invalid ${label}: ${result.error.issues.map(i => i.message).join(', ')}`
    );
  }
  return result.data;
}

export function requireScopes(
  scopes: UserScope[],
  required: UserScope[],
  action: string
): void {
  if (!checkScopes(scopes, required)) {
    throw new Error(
      `You are not authorized to ${action}. Required scopes: ${required.join(', ')}; Got: ${scopes.join(', ')}`
    );
  }
}

/**
 * Retries `fn` while it rejects with an `HttpError` whose status is 401/403,
 * which on this API surfaces as "the freshly-issued token has not yet propagated
 * through the auth cache."
 */
export async function retryOnAuthPropagation<T>(
  fn: () => Promise<T>,
  opts: {attempts?: number; baseDelayMs?: number; maxDelayMs?: number} = {}
): Promise<T> {
  const {attempts = 5, baseDelayMs = 300, maxDelayMs = 5000} = opts;
  const backoff = (attempt: number) => {
    const exp = Math.min(maxDelayMs, baseDelayMs * 3 ** attempt);
    return exp + Math.random() * 0.3 * exp;
  };

  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (!isAuthError(e) || attempt >= attempts - 1) throw e;
      await sleep(backoff(attempt));
    }
  }
}

/** Runs the fetch for one target and reduces network/parse outcomes to a tagged result. */
async function runTarget<T>(
  base: BaseClient,
  target: MultiServerTarget,
  clientHeaders: Headers | ReadonlyHeaders,
  request: {endpoint: string; init?: RequestInit; version?: APIVersion},
  schema: z.ZodType<T>,
  retryOnAuth: boolean
): Promise<MultiServerCallResult<T>> {
  const fetchOnce = () =>
    base._fetcher<unknown>({
      authToken: target.token,
      baseURL: target.url,
      clientHeaders,
      endpoint: request.endpoint,
      init: request.init,
      version: request.version ?? APIVersion.V1,
    });
  try {
    const raw = retryOnAuth
      ? await retryOnAuthPropagation(fetchOnce)
      : await fetchOnce();
    const parsed = schema.safeParse(raw);
    return parsed.success
      ? {data: parsed.data, ok: true}
      : {error: parsed.error, ok: false, raw, reason: 'parse'};
  } catch (e) {
    return {
      error: e instanceof Error ? e : new Error(String(e)),
      ok: false,
      reason: 'fetch',
      status: e instanceof HttpError ? e.status : undefined,
    };
  }
}
