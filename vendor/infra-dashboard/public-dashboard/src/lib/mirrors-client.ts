// Client-side mirror health computation — no Redis, no server functions.
// React Query handles caching in SPA mode.
// Logic extracted from mirrors.ts (server version uses swrCached wrapper).
// Intentionally does not import from github.ts (which pulls in ioredis/swrCached).

import type {Mirror, RepoCheck, RepoStatus} from './types';

const MIRRORLIST_OWNER = import.meta.env?.VITE_MIRRORLIST_OWNER ?? '';
const MIRRORLIST_REPO = import.meta.env?.VITE_MIRRORLIST_REPO ?? '';
const MIRRORLIST_PATH = import.meta.env?.VITE_MIRRORLIST_PATH ?? '';

async function fetchMirrorlist(): Promise<string[]> {
  if (!MIRRORLIST_OWNER || !MIRRORLIST_REPO || !MIRRORLIST_PATH) return [];
  const url = `https://api.github.com/repos/${MIRRORLIST_OWNER}/${MIRRORLIST_REPO}/contents/${MIRRORLIST_PATH}`;
  const res = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json',
      'User-Agent': 'infra-dashboard/public-dashboard',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  });
  if (!res.ok) return [];
  const json = await res.json();
  return atob(json.content as string)
    .split('\n')
    .filter(line => line.trim().startsWith('Server'))
    .map(line => line.trim().replace(/Server\s*=\s*/, '').replace(/\$arch\/\$repo/, '').trim());
}

const PRIMARY_MIRROR_URL =
  import.meta.env?.VITE_PRIMARY_MIRROR_URL ?? 'http://localhost:5862/repo';

const FETCH_TIMEOUT_MS = 2000;
const SYNC_TOLERANCE_SECONDS = 3600;

const REPO_PATHS: readonly string[] = (
  import.meta.env?.VITE_MIRROR_REPO_PATHS ??
  'x86_64/cachyos,x86_64_v3/cachyos-v3,x86_64_v3/cachyos-core-v3,x86_64_v3/cachyos-extra-v3'
)
  .split(',')
  .map((s: string) => s.trim())
  .filter(Boolean);

export async function computeMirrorsData() {
  const mirrorsList = await fetchMirrorlist();

  const baselinePromises = REPO_PATHS.map(async path => ({
    path,
    timestamp: await fetchRepoTimestamp(PRIMARY_MIRROR_URL, path),
  }));

  const baselines = await Promise.all(baselinePromises);
  const baselineMap = new Map(baselines.map(b => [b.path, b.timestamp]));

  const mirrorChecks = mirrorsList.map(async mirrorUrl => {
    const checks = await Promise.all(
      REPO_PATHS.map(async (path): Promise<RepoCheck> => {
        const timestamp = await fetchRepoTimestamp(mirrorUrl, path);
        const baseline = baselineMap.get(path);

        let status: RepoStatus = 'error';
        let lag: null | number = null;

        if (timestamp !== null) {
          if (baseline) {
            lag = baseline - timestamp;
            status = lag <= SYNC_TOLERANCE_SECONDS ? 'synced' : 'out-of-sync';
          } else {
            status = 'synced';
          }
        }

        return {lastUpdated: timestamp, path, status, syncLagSeconds: lag};
      })
    );

    return buildMirrorResult(mirrorUrl, checks);
  });

  const mirrors = await Promise.all(mirrorChecks);

  mirrors.sort((a, b) => {
    const score = (s: Mirror['overallStatus']) => {
      switch (s) {
        case 'error': return 3;
        case 'healthy': return 0;
        case 'out-of-sync': return 2;
        case 'partial': return 1;
      }
    };
    const statusDiff = score(a.overallStatus) - score(b.overallStatus);
    if (statusDiff !== 0) return statusDiff;
    if (a.averageLagSeconds === null && b.averageLagSeconds === null) return 0;
    if (a.averageLagSeconds === null) return 1;
    if (b.averageLagSeconds === null) return -1;
    return a.averageLagSeconds - b.averageLagSeconds;
  });

  return {baselines, mirrors};
}

function buildMirrorResult(mirrorUrl: string, checks: RepoCheck[]): Mirror {
  const validChecks = checks.filter(c => c.status !== 'error');
  const totalChecks = checks.length;
  const errorChecks = checks.length - validChecks.length;
  const syncedChecks = checks.filter(c => c.status === 'synced').length;

  let overallStatus: Mirror['overallStatus'] = 'error';
  if (validChecks.length === 0) {
    overallStatus = 'error';
  } else if (syncedChecks === totalChecks) {
    overallStatus = 'healthy';
  } else if (errorChecks > 0 || syncedChecks < totalChecks) {
    overallStatus = 'partial';
    if (syncedChecks === 0) overallStatus = 'out-of-sync';
  }

  const lags = validChecks
    .map(c => c.syncLagSeconds)
    .filter((l): l is number => l !== null)
    .filter(l => l > 0);

  const averageLag =
    lags.length > 0 ? lags.reduce((a, b) => a + b, 0) / lags.length : null;

  const url = new URL(mirrorUrl);

  return {
    averageLagSeconds: averageLag,
    checks,
    name: url.hostname,
    overallStatus,
    url: mirrorUrl,
  } satisfies Mirror;
}

async function fetchRepoTimestamp(
  baseUrl: string,
  repoPath: string
): Promise<null | number> {
  const base = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  const fullUrl = `${base}${repoPath}/lastupdate`;
  try {
    const res = await fetch(fullUrl, {
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const text = await res.text();
    const timestamp = Number.parseInt(text.trim(), 10);
    return Number.isNaN(timestamp) ? null : timestamp / 1000;
  } catch (err) {
    console.debug(`Failed to fetch ${fullUrl}:`, err);
    return null;
  }
}
