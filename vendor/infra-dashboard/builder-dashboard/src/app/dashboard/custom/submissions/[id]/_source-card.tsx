'use client';

import {ExternalLink, FileText} from 'lucide-react';

import type {PackageSubmission} from '@/lib/typings';

import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';

interface SubmissionSourceCardProps {
  submission: PackageSubmission;
}

export function SubmissionSourceCard({submission}: SubmissionSourceCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-sm font-medium">
          <FileText className="size-4" />
          Source
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <div className="flex flex-col gap-1">
          <span className="text-xs uppercase tracking-wide text-muted-foreground">
            Git repository
          </span>
          <a
            className="inline-flex items-center gap-1.5 break-all font-mono text-sm hover:text-brand hover:underline"
            href={submission.git_repo_url}
            rel="noopener noreferrer"
            target="_blank"
          >
            {submission.git_repo_url}
            <ExternalLink className="size-3 shrink-0" />
          </a>
        </div>
        {submission.pkg_path_in_repo && (
          <div className="flex flex-col gap-1">
            <span className="text-xs uppercase tracking-wide text-muted-foreground">
              Path in repo
            </span>
            <span className="font-mono text-sm">
              {submission.pkg_path_in_repo}
            </span>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
