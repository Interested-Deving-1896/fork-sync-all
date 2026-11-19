'use client';

import {ArrowLeft, ChevronRight, Shield, Trash2} from 'lucide-react';
import Link from 'next/link';
import {useParams} from 'next/navigation';
import {useCallback, useEffect, useMemo, useState} from 'react';

import {
  findMaintainersByUsername,
  getPackageSubmissions,
  revokeMaintainer,
} from '@/app/actions/custom';
import {
  labelFor,
  pulseFor,
  toneFor,
} from '@/components/custom/submission-status';
import Loader from '@/components/loader';
import {Badge} from '@/components/ui/badge';
import {Button} from '@/components/ui/button';
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {EmptyState} from '@/components/ui/empty-state';
import {MetadataRow} from '@/components/ui/metadata-row';
import {PageHeader} from '@/components/ui/page-header';
import {useSidebar} from '@/components/ui/sidebar';
import {StatusDot} from '@/components/ui/status-dot';
import {runAction} from '@/lib/toast-action';
import {
  isActionError,
  type MaintainerPolicy,
  type PackageSubmission,
  unwrapOr,
  UserScope,
} from '@/lib/typings';
import {checkScopes, unixToDate} from '@/lib/utils';

export default function MaintainerDetailPage() {
  const params = useParams<{username: string}>();
  const username = useMemo(
    () => (params?.username ? decodeURIComponent(params.username) : ''),
    [params]
  );
  const {scopes} = useSidebar();
  const isAdmin = useMemo(
    () => checkScopes(scopes, [UserScope.ADMIN]),
    [scopes]
  );

  const [data, setData] = useState<{
    loading: boolean;
    submissions: PackageSubmission[];
    userPolicies: MaintainerPolicy[];
  }>({loading: true, submissions: [], userPolicies: []});
  const [ui, setUi] = useState<{
    busy: boolean;
    revokeTarget: MaintainerPolicy | null;
  }>({busy: false, revokeTarget: null});

  const {loading, submissions, userPolicies} = data;
  const {busy, revokeTarget} = ui;

  const refresh = useCallback(async () => {
    if (!username) return;
    setData(prev => ({...prev, loading: true}));
    const [maintainers, subs] = await Promise.all([
      findMaintainersByUsername(username),
      getPackageSubmissions(),
    ]);
    // Recent reviews are derived from the first page of submissions (capped at 200).
    setData({
      loading: false,
      submissions: unwrapOr(subs, {
        submissions: [],
        total_items: 0,
        total_pages: 0,
      }).submissions,
      userPolicies: isActionError(maintainers) ? [] : maintainers,
    });
  }, [username]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const userActivity = useMemo(
    () =>
      submissions
        .filter(s => s.reviewer === username)
        .sort((a, b) => b.updated - a.updated)
        .slice(0, 15),
    [submissions, username]
  );

  const oldestGrant = useMemo(() => {
    let oldest: null | number = null;
    for (const p of userPolicies) {
      const t = unixToDate(p.granted_at).getTime();
      if (isNaN(t)) continue;
      if (oldest === null || t < oldest) oldest = t;
    }
    return oldest === null ? null : new Date(oldest);
  }, [userPolicies]);

  const autoQueueCount = userPolicies.filter(p => p.auto_queue).length;

  const handleRevoke = async () => {
    if (!revokeTarget) return;
    const target = revokeTarget;
    setUi(prev => ({...prev, busy: true}));
    try {
      await runAction(
        `Revoking ${target.pkgbase}…`,
        () => revokeMaintainer(target.id),
        {
          onSuccess: () => {
            setUi(prev => ({...prev, revokeTarget: null}));
            void refresh();
          },
          successMessage: `Revoked ${target.pkgbase}.`,
        }
      );
    } finally {
      setUi(prev => ({...prev, busy: false}));
    }
  };

  if (!isAdmin) {
    return (
      <EmptyState
        description="Maintainer management is restricted to administrators."
        icon={<Shield />}
        title="Admin access required"
      />
    );
  }

  if (loading) return <Loader animate text="Loading maintainer…" />;

  if (userPolicies.length === 0) {
    return (
      <div className="flex flex-col gap-4">
        <Link
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
          href="/dashboard/custom/maintainers"
        >
          <ArrowLeft className="size-3.5" />
          Back to maintainers
        </Link>
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            No maintainer policies found for &ldquo;{username}&rdquo;.
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-6">
      <nav className="flex items-center gap-1 text-xs text-muted-foreground">
        <Link
          className="hover:text-foreground"
          href="/dashboard/custom/maintainers"
        >
          Maintainers
        </Link>
        <ChevronRight className="size-3" />
        <span className="text-foreground">{username}</span>
      </nav>

      <PageHeader eyebrow="Maintainer" title={username}>
        <MetadataRow
          className="pt-1"
          items={[
            {label: 'packages', value: userPolicies.length},
            {label: 'auto-queue', value: autoQueueCount},
            oldestGrant && {
              label: 'since',
              value: oldestGrant.toLocaleDateString(),
            },
          ]}
        />
      </PageHeader>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">
            Granted packages
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ul className="-mx-2 flex flex-col divide-y">
            {userPolicies.map(policy => (
              <li
                className="group flex items-center gap-3 px-2 py-2.5"
                key={policy.id}
              >
                <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                  <span className="truncate text-sm font-medium">
                    {policy.pkgbase}
                  </span>
                  <MetadataRow
                    items={[
                      {value: policy.repo_name},
                      {value: policy.march},
                      {label: 'by', value: policy.granter_username},
                      {
                        value: unixToDate(
                          policy.granted_at
                        ).toLocaleDateString(),
                      },
                    ]}
                  />
                </div>
                <Badge variant={policy.auto_queue ? 'info' : 'muted'}>
                  {policy.auto_queue ? 'auto queue' : 'manual'}
                </Badge>
                <Button
                  className="opacity-0 transition-opacity group-hover:opacity-100"
                  disabled={busy}
                  onClick={() =>
                    setUi(prev => ({...prev, revokeTarget: policy}))
                  }
                  size="icon"
                  variant="ghost"
                >
                  <Trash2 className="size-4 text-muted-foreground hover:text-destructive" />
                  <span className="sr-only">Revoke</span>
                </Button>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-sm font-medium">Recent reviews</CardTitle>
        </CardHeader>
        <CardContent>
          {userActivity.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              No submissions reviewed by this user yet.
            </p>
          ) : (
            <ul className="-mx-2 flex flex-col">
              {userActivity.map(sub => (
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
                          {value: sub.repo_name},
                          {value: sub.march},
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

      <Dialog
        onOpenChange={o => !o && setUi(prev => ({...prev, revokeTarget: null}))}
        open={!!revokeTarget}
      >
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Revoke maintainer policy</DialogTitle>
            <DialogDescription>
              {revokeTarget
                ? `Revoke ${username}'s privileges on "${revokeTarget.pkgbase}" (${revokeTarget.repo_name})?`
                : null}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <DialogClose asChild>
              <Button disabled={busy} variant="outline">
                Cancel
              </Button>
            </DialogClose>
            <Button
              disabled={busy}
              onClick={handleRevoke}
              variant="destructive"
            >
              Revoke
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
