'use client';

import {useMemo, useRef, useState} from 'react';
import {toast} from 'sonner';

import {addMaintainer} from '@/app/actions/custom';
import {Button} from '@/components/ui/button';
import {Checkbox} from '@/components/ui/checkbox';
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
  type AddMaintainerRequest,
  AddMaintainerRequestSchema,
  type CustomPackage,
  type CustomRepo,
  isActionError,
} from '@/lib/typings';

interface AddMaintainerDialogProps {
  currentUser: string;
  onOpenChange: (open: boolean) => void;
  onSuccess: () => void;
  open: boolean;
  packages: CustomPackage[];
  prefill?: {pkgbase?: string; repoId?: string};
  repos: CustomRepo[];
}

export function AddMaintainerDialog({
  currentUser,
  onOpenChange,
  onSuccess,
  open,
  packages,
  prefill,
  repos,
}: Readonly<AddMaintainerDialogProps>) {
  const [form, setForm] = useState({
    autoQueue: false,
    pkgbase: prefill?.pkgbase ?? '',
    repoId: prefill?.repoId ?? '',
    username: '',
  });
  const [ui, setUi] = useState({submitting: false, suggestionsOpen: false});

  const {autoQueue, pkgbase, repoId, username} = form;
  const {submitting, suggestionsOpen} = ui;
  const pkgbaseInputRef = useRef<HTMLInputElement>(null);

  const uniquePkgbases = useMemo(() => {
    const set = new Set<string>();
    for (const pkg of packages) {
      set.add(pkg.pkgbase);
    }
    return Array.from(set).sort();
  }, [packages]);

  const filteredSuggestions = useMemo(() => {
    if (!pkgbase.trim()) return [];
    const query = pkgbase.toLowerCase();
    return uniquePkgbases
      .filter(p => p.toLowerCase().includes(query))
      .slice(0, 20);
  }, [pkgbase, uniquePkgbases]);

  const isSelfAdd =
    username.trim().length > 0 &&
    username.trim().toLowerCase() === currentUser.toLowerCase();

  function resetForm() {
    setForm({autoQueue: false, pkgbase: '', repoId: '', username: ''});
    setUi(prev => ({...prev, suggestionsOpen: false}));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (submitting || isSelfAdd) return;

    const data: AddMaintainerRequest = {
      auto_queue: autoQueue,
      pkgbase: pkgbase.trim(),
      repo_id: repoId,
      username: username.trim(),
    };

    const parsed = AddMaintainerRequestSchema.safeParse(data);
    if (!parsed.success) {
      toast.error(parsed.error.issues[0]?.message ?? 'Validation failed');
      return;
    }

    setUi(prev => ({...prev, submitting: true}));
    const toastId = toast.loading('Adding maintainer...');
    try {
      const result = await addMaintainer(parsed.data);
      if (isActionError(result)) {
        toast.error(result.error, {
          closeButton: true,
          duration: Infinity,
          id: toastId,
        });
      } else {
        toast.success(`Maintainer added for ${username.trim()}.`, {
          duration: 5000,
          id: toastId,
        });
        resetForm();
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
      setUi(prev => ({...prev, submitting: false}));
    }
  }

  return (
    <Dialog
      modal
      onOpenChange={v => {
        if (!v) resetForm();
        onOpenChange(v);
      }}
      open={open}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Add Maintainer</DialogTitle>
          <DialogDescription>
            Grant a user maintainer access to a package in a repository.
          </DialogDescription>
        </DialogHeader>
        <form className="grid gap-4" onSubmit={handleSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="maintainer-username">Username</Label>
            <Input
              id="maintainer-username"
              onChange={e =>
                setForm(prev => ({...prev, username: e.target.value}))
              }
              placeholder="e.g. johndoe"
              required
              value={username}
            />
            {isSelfAdd && (
              <p className="text-sm text-destructive">
                You already have admin access.
              </p>
            )}
          </div>
          <div className="grid gap-2">
            <Label htmlFor="maintainer-repo">Repository</Label>
            <Select
              onValueChange={v => setForm(prev => ({...prev, repoId: v}))}
              value={repoId}
            >
              <SelectTrigger className="w-full" id="maintainer-repo">
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
          <div className="grid gap-2 relative">
            <Label htmlFor="maintainer-pkgbase">Package Base</Label>
            <div className="relative">
              <Input
                id="maintainer-pkgbase"
                onBlur={() => {
                  // Defer so the suggestion button's mousedown→click can fire first.
                  setTimeout(
                    () => setUi(prev => ({...prev, suggestionsOpen: false})),
                    120
                  );
                }}
                onChange={e => {
                  setForm(prev => ({...prev, pkgbase: e.target.value}));
                  setUi(prev => ({...prev, suggestionsOpen: true}));
                }}
                onFocus={() => {
                  if (filteredSuggestions.length > 0)
                    setUi(prev => ({...prev, suggestionsOpen: true}));
                }}
                onKeyDown={e => {
                  if (e.key === 'Escape')
                    setUi(prev => ({...prev, suggestionsOpen: false}));
                }}
                placeholder="e.g. my-package"
                ref={pkgbaseInputRef}
                required
                value={pkgbase}
              />
              {suggestionsOpen && filteredSuggestions.length > 0 && (
                <div className="absolute z-50 mt-1 max-h-48 w-full overflow-y-auto rounded-md border bg-popover text-popover-foreground shadow-md">
                  {filteredSuggestions.map(suggestion => (
                    <button
                      className="w-full px-3 py-1.5 text-left text-sm hover:bg-accent hover:text-accent-foreground"
                      key={suggestion}
                      onClick={() => {
                        setForm(prev => ({...prev, pkgbase: suggestion}));
                        setUi(prev => ({...prev, suggestionsOpen: false}));
                        pkgbaseInputRef.current?.focus();
                      }}
                      onMouseDown={e => e.preventDefault()}
                      type="button"
                    >
                      {suggestion}
                    </button>
                  ))}
                </div>
              )}
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Checkbox
              checked={autoQueue}
              id="maintainer-auto-queue"
              onCheckedChange={checked =>
                setForm(prev => ({...prev, autoQueue: checked === true}))
              }
            />
            <Label htmlFor="maintainer-auto-queue">Auto Queue</Label>
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
            <Button disabled={submitting || isSelfAdd} type="submit">
              {submitting ? 'Adding...' : 'Add Maintainer'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
