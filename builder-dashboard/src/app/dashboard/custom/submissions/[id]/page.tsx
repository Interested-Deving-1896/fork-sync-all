'use client';

import {ArrowLeft} from 'lucide-react';
import Link from 'next/link';
import {useParams, useRouter} from 'next/navigation';
import {useCallback, useEffect, useMemo, useState} from 'react';

import {
  cancelSubmission,
  findSubmissionById,
  getPackageSubmissions,
  queueSubmission,
} from '@/app/actions/custom';
import {ReviewNoteDialog} from '@/components/custom/review-note-dialog';
import Loader from '@/components/loader';
import {Card, CardContent} from '@/components/ui/card';
import {useSidebar} from '@/components/ui/sidebar';
import {runAction} from '@/lib/toast-action';
import {
  isActionError,
  type PackageSubmission,
  SubmissionStatus,
  unwrapOr,
  UserScope,
} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

import {SubmissionDetailHeader} from './_header';
import {SubmissionHistoryCard} from './_history-card';
import {SubmissionLogsCard} from './_logs-card';
import {SubmissionReviewNoteCard} from './_review-note-card';
import {SubmissionSourceCard} from './_source-card';
import {SubmissionTimelineCard} from './_timeline-card';

type ReviewAction = 'approve' | 'reject';

export default function SubmissionDetailPage() {
  const params = useParams<{id: string}>();
  const router = useRouter();
  const id = params?.id;
  const {scopes, username: currentUser} = useSidebar();
  const isAdmin = useMemo(
    () => checkScopes(scopes, [UserScope.ADMIN]),
    [scopes]
  );

  const [detail, setDetail] = useState<{
    history: PackageSubmission[];
    loading: boolean;
    submission: null | PackageSubmission;
  }>({history: [], loading: true, submission: null});
  const [ui, setUi] = useState<{
    busy: boolean;
    noteAction: null | ReviewAction;
  }>({busy: false, noteAction: null});

  const {history, loading, submission} = detail;
  const {busy, noteAction} = ui;

  const refresh = useCallback(async () => {
    if (!id) return;
    setDetail(prev => ({...prev, loading: true}));
    const found = await findSubmissionById(id);
    if (isActionError(found) || found == null) {
      setDetail({history: [], loading: false, submission: null});
      return;
    }
    // History is derived from the first page of submissions; older pkgbase
    // history beyond the first page is not displayed (capped at 200 items).
    const recent = await getPackageSubmissions();
    const pool = unwrapOr(recent, {
      submissions: [],
      total_items: 0,
      total_pages: 0,
    }).submissions;
    setDetail({
      history: pool
        .filter(s => s.pkgbase === found.pkgbase && s.id !== found.id)
        .sort((a, b) => b.updated - a.updated)
        .slice(0, 10),
      loading: false,
      submission: found,
    });
  }, [id]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleQueue = useCallback(async () => {
    if (!submission) return;
    setUi(prev => ({...prev, busy: true}));
    try {
      await runAction('Queueing build…', () => queueSubmission(submission.id), {
        onSuccess: () => void refresh(),
        successMessage: 'Build queued.',
      });
    } finally {
      setUi(prev => ({...prev, busy: false}));
    }
  }, [submission, refresh]);

  const handleCancel = useCallback(async () => {
    if (!submission) return;
    setUi(prev => ({...prev, busy: true}));
    try {
      await runAction('Cancelling…', () => cancelSubmission(submission.id), {
        onSuccess: () => void refresh(),
        successMessage: 'Cancelled.',
      });
    } finally {
      setUi(prev => ({...prev, busy: false}));
    }
  }, [submission, refresh]);

  if (loading) return <Loader animate text="Loading submission…" />;

  if (!submission) {
    return (
      <div className="flex flex-col gap-4">
        <Link
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
          href="/dashboard/custom/submissions"
        >
          <ArrowLeft className="size-3.5" />
          Back to submissions
        </Link>
        <Card>
          <CardContent className="py-12 text-center text-muted-foreground">
            Submission not found.
          </CardContent>
        </Card>
      </div>
    );
  }

  const showLogs =
    submission.submission_status === SubmissionStatus.BUILD_FAILED;

  return (
    <div className="flex flex-col gap-6">
      <SubmissionDetailHeader
        busy={busy}
        currentUser={currentUser}
        isAdmin={isAdmin}
        onApprove={() => setUi(prev => ({...prev, noteAction: 'approve'}))}
        onCancel={handleCancel}
        onQueue={handleQueue}
        onReject={() => setUi(prev => ({...prev, noteAction: 'reject'}))}
        submission={submission}
      />

      <div className="grid gap-6 md:grid-cols-3">
        <div className="flex flex-col gap-6 md:col-span-2">
          <SubmissionTimelineCard submission={submission} />
          {showLogs && <SubmissionLogsCard submission={submission} />}
          <SubmissionSourceCard submission={submission} />
        </div>

        <div className="flex flex-col gap-6">
          <SubmissionReviewNoteCard note={submission.review_note} />
          <SubmissionHistoryCard
            history={history}
            pkgbase={submission.pkgbase}
          />
        </div>
      </div>

      {noteAction && (
        <ReviewNoteDialog
          action={noteAction}
          onOpenChange={open =>
            !open && setUi(prev => ({...prev, noteAction: null}))
          }
          onSuccess={() => {
            setUi(prev => ({...prev, noteAction: null}));
            void refresh();
            router.refresh();
          }}
          open={!!noteAction}
          submissionId={submission.id}
        />
      )}
    </div>
  );
}
