'use client';

import {ChevronRight} from 'lucide-react';
import Link from 'next/link';

import {
  labelFor,
  pulseFor,
  toneFor,
} from '@/components/custom/submission-status';
import {Button} from '@/components/ui/button';
import {MetadataRow} from '@/components/ui/metadata-row';
import {PageHeader} from '@/components/ui/page-header';
import {StatusDot} from '@/components/ui/status-dot';
import {type PackageSubmission, SubmissionStatus} from '@/lib/typings';

interface SubmissionDetailHeaderProps {
  busy: boolean;
  currentUser: string;
  isAdmin: boolean;
  onApprove: () => void;
  onCancel: () => void;
  onQueue: () => void;
  onReject: () => void;
  submission: PackageSubmission;
}

export function SubmissionDetailHeader({
  busy,
  currentUser,
  isAdmin,
  onApprove,
  onCancel,
  onQueue,
  onReject,
  submission,
}: SubmissionDetailHeaderProps) {
  const status = submission.submission_status;
  const canApproveReject =
    isAdmin && status === SubmissionStatus.PENDING_REVIEW;
  const canQueue = isAdmin && status === SubmissionStatus.APPROVED;
  const canCancel =
    (isAdmin || submission.submitter === currentUser) &&
    (status === SubmissionStatus.APPROVED ||
      status === SubmissionStatus.BUILD_QUEUED);

  return (
    <>
      <nav className="flex items-center gap-1 text-xs text-muted-foreground">
        <Link
          className="hover:text-foreground"
          href="/dashboard/custom/submissions"
        >
          Submissions
        </Link>
        <ChevronRight className="size-3" />
        <span className="text-foreground">{submission.pkgbase}</span>
      </nav>

      <PageHeader
        actions={
          <>
            {canApproveReject && (
              <>
                <Button
                  disabled={busy}
                  onClick={onApprove}
                  size="sm"
                  variant="brand"
                >
                  Approve
                </Button>
                <Button
                  disabled={busy}
                  onClick={onReject}
                  size="sm"
                  variant="destructive"
                >
                  Reject
                </Button>
              </>
            )}
            {canQueue && (
              <Button
                disabled={busy}
                onClick={onQueue}
                size="sm"
                variant="brand"
              >
                Queue build
              </Button>
            )}
            {canCancel && (
              <Button
                disabled={busy}
                onClick={onCancel}
                size="sm"
                variant="outline"
              >
                Cancel
              </Button>
            )}
          </>
        }
        eyebrow="Submission"
        title={
          <>
            <StatusDot pulse={pulseFor(status)} tone={toneFor(status)} />
            <span className="font-mono">{submission.pkgbase}</span>
          </>
        }
      >
        <MetadataRow
          className="pt-1"
          items={[
            {label: 'status', value: labelFor(status)},
            {label: 'arch', value: submission.march},
            {label: 'repo', value: submission.repo_name},
            {label: 'submitter', value: submission.submitter},
            submission.reviewer
              ? {label: 'reviewer', value: submission.reviewer}
              : null,
            {
              label: 'created',
              value: new Date(submission.created * 1000).toLocaleString(),
            },
            {
              label: 'updated',
              value: new Date(submission.updated * 1000).toLocaleString(),
            },
          ]}
        />
      </PageHeader>
    </>
  );
}
