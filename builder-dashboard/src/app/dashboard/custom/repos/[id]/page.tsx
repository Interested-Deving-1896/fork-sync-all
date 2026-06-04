'use client';

import {ArrowLeft, ChevronRight} from 'lucide-react';
import Link from 'next/link';
import {useParams} from 'next/navigation';
import {useEffect, useMemo, useState} from 'react';

import {
  findRepoById,
  getCustomPackages,
  getPackageSubmissions,
} from '@/app/actions/custom';
import {
  pulseFor as pkgPulseFor,
  toneFor as pkgToneFor,
} from '@/components/custom/package-status';
import {
  labelFor,
  pulseFor,
  toneFor,
} from '@/components/custom/submission-status';
import Loader from '@/components/loader';
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';
import {MetadataRow} from '@/components/ui/metadata-row';
import {PageHeader} from '@/components/ui/page-header';
import {StatusDot} from '@/components/ui/status-dot';
import {
  type CustomPackage,
  type CustomRepo,
  isActionError,
  type PackageSubmission,
  SubmissionStatus,
  unwrapOr,
} from '@/lib/typings';

const THIRTY_DAYS = 30 * 24 * 60 * 60 * 1000;

interface RepoData {
  loading: boolean;
  packages: CustomPackage[];
  repo: CustomRepo | null;
  submissions: PackageSubmission[];
}

export default function RepoDetailPage() {
  const params = useParams<{id: string}>();
  const id = params?.id;

  const [data, setData] = useState<RepoData>({
    loading: true,
    packages: [],
    repo: null,
    submissions: [],
  });
  const [now] = useState(() => Date.now());

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    // Aggregates summarize the first page of packages/submissions (capped at 200).
    // For larger repos the percentages reflect a sample, not the full dataset.
    Promise.all([
      findRepoById(id),
      getCustomPackages(),
      getPackageSubmissions(),
    ]).then(([repoResult, ps, ss]) => {
      if (cancelled) return;
      setData({
        loading: false,
        packages: unwrapOr(ps, {
          custom_packages: [],
          total_items: 0,
          total_pages: 0,
        }).custom_packages,
        repo: isActionError(repoResult) ? null : repoResult,
        submissions: unwrapOr(ss, {
          submissions: [],
          total_items: 0,
          total_pages: 0,
        }).submissions,
      });
    });
    return () => {
      cancelled = true;
    };
  }, [id]);

  const {loading, packages, repo, submissions} = data;

  const repoPackages = useMemo(() => {
    if (!repo) return [];
    return packages
      .filter(p => p.repository === repo.repo_name)
      .sort((a, b) => b.updated - a.updated);
  }, [packages, repo]);

  const repoSubmissions = useMemo(() => {
    if (!repo) return [];
    return submissions
      .filter(s => s.repo_name === repo.repo_name)
      .sort((a, b) => b.updated - a.updated);
  }, [submissions, repo]);

  const successRate = useMemo(() => {
    if (!repo) return null;
    const recent = repoSubmissions.filter(
      s => now - s.updated * 1000 < THIRTY_DAYS
    );
    const prior = repoSubmissions.filter(s => {
      const age = now - s.updated * 1000;
      return age >= THIRTY_DAYS && age < THIRTY_DAYS * 2;
    });
    const ratio = (set: PackageSubmission[]) => {
      const done = set.filter(
        s => s.submission_status === SubmissionStatus.BUILD_DONE
      ).length;
      const failed = set.filter(
        s => s.submission_status === SubmissionStatus.BUILD_FAILED
      ).length;
      const total = done + failed;
      return total === 0 ? null : done / total;
    };
    return {
      prior: ratio(prior),
      recent: ratio(recent),
      recentCount: recent.length,
    };
  }, [repoSubmissions, repo, now]);

  if (loading) return <Loader animate text="Loading repo…" />;

  if (!repo) {
    return (
      <div className="flex flex-col gap-4">
        <Link
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
          href="/dashboard/custom/repos"
        >
          <ArrowLeft className="size-3.5" />
          Back to repos
        </Link>
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            Repository not found.
          </CardContent>
        </Card>
      </div>
    );
  }

  const recentRate = successRate?.recent;
  const priorRate = successRate?.prior;
  const delta =
    recentRate != null && priorRate != null ? recentRate - priorRate : null;

  return (
    <div className="flex flex-col gap-6">
      <nav className="flex items-center gap-1 text-xs text-muted-foreground">
        <Link className="hover:text-foreground" href="/dashboard/custom/repos">
          Repos
        </Link>
        <ChevronRight className="size-3" />
        <span className="text-foreground">{repo.repo_name}</span>
      </nav>

      <PageHeader
        eyebrow="Repo"
        title={<span className="font-mono">{repo.repo_name}</span>}
      >
        <MetadataRow
          className="pt-1"
          items={[
            {label: 'arch', value: repo.march},
            {label: 'id', mono: true, value: repo.id},
          ]}
        />
      </PageHeader>

      <div className="grid gap-6 md:grid-cols-3">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium">
              Build success (30d)
            </CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-1">
            <span className="text-3xl font-semibold tracking-tight">
              {recentRate == null ? '—' : `${Math.round(recentRate * 100)}%`}
            </span>
            <span className="text-xs text-muted-foreground">
              {successRate?.recentCount ?? 0} build
              {(successRate?.recentCount ?? 0) === 1 ? '' : 's'}
              {delta != null && (
                <>
                  {' · '}
                  <span
                    className={
                      delta >= 0 ? 'text-status-success' : 'text-status-danger'
                    }
                  >
                    {delta >= 0 ? '+' : ''}
                    {Math.round(delta * 100)}% vs prior 30d
                  </span>
                </>
              )}
            </span>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium">Packages</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-1">
            <span className="text-3xl font-semibold tracking-tight">
              {repoPackages.length}
            </span>
            <span className="text-xs text-muted-foreground">
              tracked in this repo
            </span>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm font-medium">Submissions</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col gap-1">
            <span className="text-3xl font-semibold tracking-tight">
              {repoSubmissions.length}
            </span>
            <span className="text-xs text-muted-foreground">total</span>
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">
            Packages in this repo
          </CardTitle>
        </CardHeader>
        <CardContent>
          {repoPackages.length === 0 ? (
            <p className="text-sm text-muted-foreground">No packages yet.</p>
          ) : (
            <ul className="-mx-2 flex flex-col">
              {repoPackages.slice(0, 50).map(pkg => (
                <li
                  className="flex items-center gap-3 rounded-md p-2 hover:bg-muted/50"
                  key={`${pkg.march}-${pkg.pkgname}`}
                >
                  <StatusDot
                    pulse={pkgPulseFor(pkg.status)}
                    tone={pkgToneFor(pkg.status)}
                  />
                  <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                    <span className="truncate text-sm font-medium">
                      {pkg.pkgbase}
                    </span>
                    <MetadataRow
                      items={[
                        {value: pkg.pkgname},
                        {value: pkg.march},
                        {label: 'v', mono: true, value: pkg.version},
                        {value: new Date(pkg.updated * 1000).toLocaleString()},
                      ]}
                    />
                  </div>
                  <span className="text-xs text-muted-foreground">
                    {pkg.status}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">
            Recent submissions
          </CardTitle>
        </CardHeader>
        <CardContent>
          {repoSubmissions.length === 0 ? (
            <p className="text-sm text-muted-foreground">No submissions yet.</p>
          ) : (
            <ul className="-mx-2 flex flex-col">
              {repoSubmissions.slice(0, 20).map(sub => (
                <li key={sub.id}>
                  <Link
                    className="flex items-center gap-3 rounded-md p-2 hover:bg-muted/50"
                    href={`/dashboard/custom/submissions/${sub.id}`}
                  >
                    <StatusDot
                      pulse={pulseFor(sub.submission_status)}
                      tone={toneFor(sub.submission_status)}
                    />
                    <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                      <span className="truncate text-sm font-medium">
                        {sub.pkgbase}
                      </span>
                      <MetadataRow
                        items={[
                          {value: sub.march},
                          {value: `by ${sub.submitter}`},
                          {
                            value: new Date(
                              sub.updated * 1000
                            ).toLocaleString(),
                          },
                        ]}
                      />
                    </div>
                    <span className="text-xs text-muted-foreground">
                      {labelFor(sub.submission_status)}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
