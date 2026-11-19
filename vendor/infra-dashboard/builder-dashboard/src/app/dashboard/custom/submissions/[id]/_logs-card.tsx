'use client';

import {ExternalLink, Logs} from 'lucide-react';
import Link from 'next/link';

import type {PackageSubmission} from '@/lib/typings';

import {Button} from '@/components/ui/button';
import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';

interface SubmissionLogsCardProps {
  submission: PackageSubmission;
}

export function SubmissionLogsCard({submission}: SubmissionLogsCardProps) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between">
        <CardTitle className="flex items-center gap-2 text-sm font-medium">
          <Logs className="size-4" />
          Build logs
        </CardTitle>
        <Button asChild size="xs" variant="outline">
          <Link
            href={`/dashboard/logs/${encodeURIComponent(submission.march)}/${encodeURIComponent(submission.pkgbase)}`}
          >
            Open full view
            <ExternalLink className="size-3" />
          </Link>
        </Button>
      </CardHeader>
      <CardContent className="text-sm text-muted-foreground">
        This build failed. Open the full log viewer to inspect the output.
      </CardContent>
    </Card>
  );
}
