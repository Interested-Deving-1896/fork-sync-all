'use client';

import Link from 'next/link';

import type {PackageSubmission} from '@/lib/typings';

import {
  labelFor,
  pulseFor,
  toneFor,
} from '@/components/custom/submission-status';
import {Badge} from '@/components/ui/badge';
import {Checkbox} from '@/components/ui/checkbox';
import {MetadataRow} from '@/components/ui/metadata-row';
import {StatusDot} from '@/components/ui/status-dot';

import {badgeVariantFor} from './_types';

interface SubmissionRowProps {
  onToggle: (id: string) => void;
  selected: boolean;
  submission: PackageSubmission;
}

export function SubmissionRow({
  onToggle,
  selected,
  submission,
}: SubmissionRowProps) {
  const status = submission.submission_status;
  return (
    <li
      className="group flex items-center gap-3 px-4 py-3 transition-colors hover:bg-muted/50 data-[checked=true]:bg-brand/5"
      data-checked={selected}
    >
      <Checkbox
        aria-label={`Select ${submission.pkgbase}`}
        checked={selected}
        onCheckedChange={() => onToggle(submission.id)}
      />
      <StatusDot pulse={pulseFor(status)} tone={toneFor(status)} />
      <Link
        className="flex min-w-0 flex-1 flex-col gap-0.5"
        href={`/dashboard/custom/submissions/${submission.id}`}
      >
        <span className="truncate text-sm font-medium">
          {submission.pkgbase}
        </span>
        <MetadataRow
          items={[
            {value: submission.march},
            {value: submission.repo_name},
            {value: `by ${submission.submitter}`},
            {value: new Date(submission.updated * 1000).toLocaleString()},
          ]}
        />
      </Link>
      <Badge variant={badgeVariantFor(status)}>{labelFor(status)}</Badge>
    </li>
  );
}
