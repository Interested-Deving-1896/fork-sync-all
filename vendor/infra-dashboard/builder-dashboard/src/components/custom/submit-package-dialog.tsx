'use client';

import {useState} from 'react';
import {toast} from 'sonner';

import {submitPackage} from '@/app/actions/custom';
import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {Input} from '@/components/ui/input';
import {Label} from '@/components/ui/label';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  type CustomRepo,
  isActionError,
  type SubmitPackageRequest,
  SubmitPackageRequestSchema,
} from '@/lib/typings';

interface SubmitPackageDialogProps {
  onOpenChange: (open: boolean) => void;
  onSuccess: () => void;
  open: boolean;
  repos: CustomRepo[];
}

export function SubmitPackageDialog({
  onOpenChange,
  onSuccess,
  open,
  repos,
}: Readonly<SubmitPackageDialogProps>) {
  const [repoId, setRepoId] = useState('');
  const [pkgbase, setPkgbase] = useState('');
  const [gitRepoUrl, setGitRepoUrl] = useState('');
  const [pkgPathInRepo, setPkgPathInRepo] = useState('');
  const [submitting, setSubmitting] = useState(false);

  function resetForm() {
    setRepoId('');
    setPkgbase('');
    setGitRepoUrl('');
    setPkgPathInRepo('');
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (submitting) return;

    const data: SubmitPackageRequest = {
      git_repo_url: gitRepoUrl,
      pkg_path_in_repo: pkgPathInRepo || '',
      pkgbase,
      repo_id: repoId,
    };

    const parsed = SubmitPackageRequestSchema.safeParse(data);
    if (!parsed.success) {
      const firstError = parsed.error.issues[0];
      toast.error(firstError?.message ?? 'Validation failed');
      return;
    }

    setSubmitting(true);
    const toastId = toast.loading('Submitting package...');
    try {
      const result = await submitPackage(parsed.data);
      if (isActionError(result)) {
        toast.error(result.error, {
          closeButton: true,
          duration: Infinity,
          id: toastId,
        });
      } else {
        toast.success('Package submitted successfully.', {
          duration: 5000,
          id: toastId,
        });
        resetForm();
        onOpenChange(false);
        onSuccess();
      }
    } catch {
      toast.error(
        'An unexpected error occurred while submitting the package.',
        {
          closeButton: true,
          duration: Infinity,
          id: toastId,
        }
      );
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Dialog modal onOpenChange={onOpenChange} open={open}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Submit Package</DialogTitle>
          <DialogDescription>
            Submit a new package for review and building.
          </DialogDescription>
        </DialogHeader>
        <form className="grid gap-4" onSubmit={handleSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="submit-repo">Repository</Label>
            <Select onValueChange={setRepoId} value={repoId}>
              <SelectTrigger className="w-full" id="submit-repo">
                <SelectValue placeholder="Select a repository" />
              </SelectTrigger>
              <SelectContent>
                {repos.map(repo => (
                  <SelectItem key={repo.id} value={repo.id}>
                    {repo.repo_name} ({repo.march})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
          <div className="grid gap-2">
            <Label htmlFor="submit-pkgbase">Package Base</Label>
            <Input
              id="submit-pkgbase"
              onChange={e => setPkgbase(e.target.value)}
              placeholder="e.g. my-package"
              required
              value={pkgbase}
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="submit-git-url">Git Repository URL</Label>
            <Input
              id="submit-git-url"
              onChange={e => setGitRepoUrl(e.target.value)}
              placeholder="https://github.com/user/repo.git"
              required
              value={gitRepoUrl}
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="submit-pkg-path">Package Path in Repo</Label>
            <Input
              id="submit-pkg-path"
              onChange={e => setPkgPathInRepo(e.target.value)}
              placeholder="Optional subdirectory path"
              value={pkgPathInRepo}
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
            <Button disabled={submitting} type="submit">
              {submitting ? 'Submitting...' : 'Submit Package'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
