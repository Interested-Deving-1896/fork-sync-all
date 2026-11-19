'use client';

import {useMemo} from 'react';

import {
  labelFor,
  pulseFor,
  toneFor,
} from '@/components/custom/submission-status';
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';
import {Timeline, type TimelineEvent} from '@/components/ui/timeline';
import {type PackageSubmission, SubmissionStatus} from '@/lib/typings';

interface SubmissionTimelineCardProps {
  submission: PackageSubmission;
}

export function SubmissionTimelineCard({
  submission,
}: SubmissionTimelineCardProps) {
  const events = useMemo<TimelineEvent[]>(() => {
    const out: TimelineEvent[] = [
      {
        body: (
          <span className="font-mono text-xs">
            {submission.git_repo_url}
            {submission.pkg_path_in_repo
              ? ` · ${submission.pkg_path_in_repo}`
              : ''}
          </span>
        ),
        id: 'created',
        meta: `${new Date(submission.created * 1000).toLocaleString()} · by ${submission.submitter}`,
        title: 'Submitted',
        tone: 'info',
      },
    ];
    if (
      submission.updated > submission.created ||
      submission.submission_status !== SubmissionStatus.PENDING_REVIEW
    ) {
      out.push({
        body: submission.review_note ? (
          <span className="italic">“{submission.review_note}”</span>
        ) : undefined,
        id: 'status',
        meta: `${new Date(submission.updated * 1000).toLocaleString()}${submission.reviewer ? ` · by ${submission.reviewer}` : ''}`,
        pulse: pulseFor(submission.submission_status),
        title: labelFor(submission.submission_status),
        tone: toneFor(submission.submission_status),
      });
    }
    return out;
  }, [submission]);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm font-medium">Timeline</CardTitle>
      </CardHeader>
      <CardContent>
        {events.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No events recorded yet.
          </p>
        ) : (
          <Timeline events={events} />
        )}
      </CardContent>
    </Card>
  );
}
