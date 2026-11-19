'use client';

import {useState} from 'react';
import {toast} from 'sonner';

import {approveSubmission, rejectSubmission} from '@/app/actions/custom';
import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {Label} from '@/components/ui/label';
import {Textarea} from '@/components/ui/textarea';
import {isActionError} from '@/lib/typings';

interface ReviewNoteDialogProps {
  action: 'approve' | 'reject';
  onOpenChange: (open: boolean) => void;
  onSuccess: () => void;
  open: boolean;
  submissionId: string;
}

export function ReviewNoteDialog({
  action,
  onOpenChange,
  onSuccess,
  open,
  submissionId,
}: Readonly<ReviewNoteDialogProps>) {
  const [note, setNote] = useState('');
  const [submitting, setSubmitting] = useState(false);

  const isApprove = action === 'approve';
  const title = isApprove ? 'Approve Submission' : 'Reject Submission';
  const description = isApprove
    ? 'Approve this package submission. You may attach an optional note.'
    : 'Reject this package submission. You may attach an optional note explaining the reason.';

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (submitting) return;

    setSubmitting(true);
    const toastId = toast.loading(
      isApprove ? 'Approving submission...' : 'Rejecting submission...'
    );
    try {
      const serverAction = isApprove ? approveSubmission : rejectSubmission;
      const result = await serverAction(submissionId, note || undefined);
      if (isActionError(result)) {
        toast.error(result.error, {
          closeButton: true,
          duration: Infinity,
          id: toastId,
        });
      } else {
        toast.success(
          isApprove
            ? 'Submission approved successfully.'
            : 'Submission rejected successfully.',
          {
            duration: 5000,
            id: toastId,
          }
        );
        setNote('');
        onOpenChange(false);
        onSuccess();
      }
    } catch {
      toast.error('An unexpected error occurred.', {
        closeButton: true,
        duration: Infinity,
        id: toastId,
      });
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Dialog modal onOpenChange={onOpenChange} open={open}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{description}</DialogDescription>
        </DialogHeader>
        <form className="grid gap-4" onSubmit={handleSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="review-note">Note (optional)</Label>
            <Textarea
              id="review-note"
              onChange={e => setNote(e.target.value)}
              placeholder={
                isApprove
                  ? 'Optional approval note...'
                  : 'Optional rejection reason...'
              }
              value={note}
            />
          </div>
          <DialogFooter>
            <Button
              disabled={submitting}
              onClick={() => onOpenChange(false)}
              type="button"
              variant="outline"
            >
              Cancel
            </Button>
            <Button
              disabled={submitting}
              type="submit"
              variant={isApprove ? 'default' : 'destructive'}
            >
              {submitting
                ? isApprove
                  ? 'Approving...'
                  : 'Rejecting...'
                : isApprove
                  ? 'Approve'
                  : 'Reject'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
