'use client';

import {Card, CardContent, CardHeader, CardTitle} from '@/components/ui/card';

interface SubmissionReviewNoteCardProps {
  note: string | undefined;
}

export function SubmissionReviewNoteCard({
  note,
}: SubmissionReviewNoteCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-sm font-medium">Review note</CardTitle>
      </CardHeader>
      <CardContent>
        {note ? (
          <p className="whitespace-pre-wrap text-sm">{note}</p>
        ) : (
          <p className="text-sm text-muted-foreground">
            No review note attached.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
