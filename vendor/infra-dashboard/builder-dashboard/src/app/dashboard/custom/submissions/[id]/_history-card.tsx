'use client';

import Link from 'next/link';

import type {PackageSubmission} from '@/lib/typings';

import {labelFor, toneFor} from '@/components/custom/submission-status';
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';
import {StatusDot} from '@/components/ui/status-dot';

interface SubmissionHistoryCardProps {
  history: ReadonlyArray<PackageSubmission>;
  pkgbase: string;
}

export function SubmissionHistoryCard({
  history,
  pkgbase,
}: SubmissionHistoryCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm font-medium">
          History for {pkgbase}
        </CardTitle>
      </CardHeader>
      <CardContent>
        {history.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No prior submissions for this package.
          </p>
        ) : (
          <ul className="flex flex-col gap-2">
            {history.map(prev => (
              <li key={prev.id}>
                <Link
                  className="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-muted/60"
                  href={`/dashboard/custom/submissions/${prev.id}`}
                >
                  <StatusDot tone={toneFor(prev.submission_status)} />
                  <span className="flex-1 truncate text-xs">
                    {labelFor(prev.submission_status)} ·{' '}
                    {new Date(prev.updated * 1000).toLocaleDateString()}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  );
}
