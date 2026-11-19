import {z} from 'zod';

import {PROFILES, swrCached} from '@/lib/server/swr-cache';

const GitTreeItemSchema = z.object({
  mode: z.string(),
  path: z.string(),
  sha: z.string(),
  size: z.number().optional(),
  type: z.enum(['blob', 'tree', 'commit']),
  url: z.url(),
});

const GitTreeResponseSchema = z.object({
  sha: z.string(),
  tree: z.array(GitTreeItemSchema),
  truncated: z.boolean(),
  url: z.url(),
});

export type GitTreeResponse = z.infer<typeof GitTreeResponseSchema>;

const GitContentItemSchema = z.object({
  content: z.string(),
});

/**
 * Maps package names to their relative PKGBUILD paths.
 * @example { "linux-cachyos": "linux-cachyos", "linux-api-headers": "toolchain/linux-api-headers" }
 */
export type PkgbuildMap = Record<string, string>;

// MIRRORLIST_OWNER / MIRRORLIST_REPO / MIRRORLIST_PATH configure where the
// mirrorlist file is fetched from. Defaults produce no results when unset.
const MIRRORLIST_OWNER =
  import.meta.env?.VITE_MIRRORLIST_OWNER ??
  globalThis.process?.env?.MIRRORLIST_OWNER ??
  '';
const MIRRORLIST_REPO =
  import.meta.env?.VITE_MIRRORLIST_REPO ??
  globalThis.process?.env?.MIRRORLIST_REPO ??
  '';
const MIRRORLIST_PATH =
  import.meta.env?.VITE_MIRRORLIST_PATH ??
  globalThis.process?.env?.MIRRORLIST_PATH ??
  '';

export async function fetchMirrorlist(
  params: {owner?: string; path?: string; repo?: string; token?: string} = {}
): Promise<Array<string>> {
  const {
    owner = MIRRORLIST_OWNER,
    path = MIRRORLIST_PATH,
    repo = MIRRORLIST_REPO,
    token = import.meta.env.GITHUB_TOKEN,
  } = params;

  if (!owner || !repo || !path) return [];

  const url = `https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(
    repo
  )}/contents/${encodeURIComponent(path)}`;

  return swrCached(
    `github:mirrorlist:${url}`,
    () => fetchMirrorlistFromGithub(url, token),
    PROFILES.github
  );
}

export async function fetchPkgbuilds(
  params: {owner?: string; ref?: string; repo?: string; token?: string} = {}
): Promise<PkgbuildMap> {
  const {
    owner = '',
    ref = 'master',
    repo = '',
    token = import.meta.env.GITHUB_TOKEN,
  } = params;

  if (!owner || !repo) return {};

  const url = `https://api.github.com/repos/${encodeURIComponent(owner)}/${encodeURIComponent(
    repo
  )}/git/trees/${encodeURIComponent(ref)}?recursive=1`;

  return swrCached(
    `github:pkgbuilds:${url}`,
    () => fetchPkgbuildsFromGithub(url, token),
    PROFILES.github
  );
}

async function fetchMirrorlistFromGithub(
  url: string,
  token?: string
): Promise<string[]> {
  const res = await fetch(url, {
    headers: getHeaders(token),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `GitHub API error ${res.status}: ${text || res.statusText}`
    );
  }

  const json = await res.json();
  const data = GitContentItemSchema.parse(json);

  return atob(data.content)
    .split('\n')
    .filter(line => line.trim().startsWith('Server'))
    .map(line =>
      line
        .trim()
        .replace(/Server\s*=\s*/, '')
        .replace(/\$arch\/\$repo/, '')
        .trim()
    );
}

async function fetchPkgbuildsFromGithub(
  url: string,
  token?: string
): Promise<PkgbuildMap> {
  const res = await fetch(url, {
    headers: getHeaders(token),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(
      `GitHub API error ${res.status}: ${text || res.statusText}`
    );
  }

  const json = await res.json();
  const data = GitTreeResponseSchema.parse(json);

  return data.tree
    .filter(node => node.path.endsWith('PKGBUILD'))
    .map(node => node.path.replace(/\/PKGBUILD$/, ''))
    .reduce((acc, path) => {
      acc[path.split('/').pop() ?? ''] = path;
      return acc;
    }, {} as PkgbuildMap);
}

function getHeaders(token?: string) {
  return {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'infra-dashboard/public-dashboard',
    'X-GitHub-Api-Version': '2022-11-28',
    ...(token ? {Authorization: `Bearer ${token}`} : {}),
  };
}
