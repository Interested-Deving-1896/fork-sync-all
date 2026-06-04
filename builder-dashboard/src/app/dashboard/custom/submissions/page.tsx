'use client';

import {FileCheck, Plus} from 'lucide-react';
import {useCallback, useEffect, useMemo, useState} from 'react';

import {getCustomRepos, getPackageSubmissions} from '@/app/actions/custom';
import {SubmitPackageDialog} from '@/components/custom/submit-package-dialog';
import Loader from '@/components/loader';
import {Button} from '@/components/ui/button';
import {Checkbox} from '@/components/ui/checkbox';
import {EmptyState} from '@/components/ui/empty-state';
import {PageHeader} from '@/components/ui/page-header';
import {useSidebar} from '@/components/ui/sidebar';
import {useInfiniteList} from '@/lib/hooks/use-infinite-list';
import {type SavedView, useSavedViews} from '@/lib/saved-views';
import {
  type CustomRepo,
  isActionError,
  type PackageSubmission,
  unwrapOr,
  UserScope,
} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

import {BulkActionDialog} from './_bulk-dialog';
import {SubmissionFilterBar} from './_filter-bar';
import {SubmissionRow} from './_row';
import {SubmissionSelectionBar} from './_selection-bar';
import {BUILTIN_VIEWS, DEFAULT_FILTERS, type SubmissionFilters} from './_types';
import {useBulkSubmissionActions} from './_use-bulk-actions';

const ONE_DAY_MS = 24 * 60 * 60 * 1000;

interface ViewState {
  activeViewId: null | string;
  filters: SubmissionFilters;
}

const INITIAL_VIEW: ViewState = {
  activeViewId: null,
  filters: DEFAULT_FILTERS,
};

export default function SubmissionsListPage() {
  const {scopes, username: currentUser} = useSidebar();
  const isAdmin = useMemo(
    () => checkScopes(scopes, [UserScope.ADMIN]),
    [scopes]
  );
  const canSubmit = useMemo(
    () =>
      checkScopes(scopes, [UserScope.PACKAGER]) ||
      checkScopes(scopes, [UserScope.ADMIN]),
    [scopes]
  );

  const [repos, setRepos] = useState<CustomRepo[]>([]);
  const [view, setView] = useState<ViewState>(INITIAL_VIEW);
  const [pageUi, setPageUi] = useState<{
    now: number;
    selected: Set<string>;
    submitOpen: boolean;
  }>(() => ({now: Date.now(), selected: new Set(), submitOpen: false}));

  const {activeViewId, filters} = view;
  const {now, selected, submitOpen} = pageUi;
  const setSubmitOpen = useCallback(
    (open: boolean) => setPageUi(prev => ({...prev, submitOpen: open})),
    []
  );

  const fetchPage = useCallback(async (page: number, size: number) => {
    const r = await getPackageSubmissions(undefined, page, size);
    if (isActionError(r)) return r;
    return {items: r.submissions, totalPages: r.total_pages};
  }, []);

  const {
    hasMore,
    items: submissions,
    loading,
    reload: refresh,
    sentinelRef,
  } = useInfiniteList<PackageSubmission>(fetchPage);

  useEffect(() => {
    getCustomRepos().then(r => {
      setRepos(unwrapOr(r, {repos: [], total_items: 0, total_pages: 0}).repos);
    });
  }, []);

  const {remove, save, views} = useSavedViews<SubmissionFilters>(
    'custom.submissions.savedViews',
    BUILTIN_VIEWS
  );

  const archOptions = useMemo(() => {
    const s = new Set<string>();
    for (const x of submissions) s.add(x.march);
    return Array.from(s).sort();
  }, [submissions]);

  const filtered = useMemo(() => {
    const q = filters.search.trim().toLowerCase();
    const cutoff = now - ONE_DAY_MS;
    return submissions.filter(s => {
      if (filters.status !== 'ALL' && s.submission_status !== filters.status)
        return false;
      if (filters.repo !== 'ALL' && s.repo_name !== filters.repo) return false;
      if (filters.arch !== 'ALL' && s.march !== filters.arch) return false;
      if (filters.recentOnly && s.updated * 1000 < cutoff) return false;
      if (q) {
        const hay =
          `${s.pkgbase} ${s.git_repo_url} ${s.submitter}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [submissions, filters, now]);

  const allChecked =
    filtered.length > 0 && filtered.every(f => selected.has(f.id));
  const someChecked = selected.size > 0;

  const clearSelection = useCallback(
    () => setPageUi(prev => ({...prev, selected: new Set()})),
    []
  );

  const toggleAll = useCallback(() => {
    setPageUi(prev => {
      const next = filtered.every(f => prev.selected.has(f.id))
        ? new Set<string>()
        : new Set(filtered.map(f => f.id));
      return {...prev, selected: next};
    });
  }, [filtered]);

  const toggleOne = useCallback((id: string) => {
    setPageUi(prev => {
      const next = new Set(prev.selected);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return {...prev, selected: next};
    });
  }, []);

  const handleSelectView = useCallback(
    (next: SavedView<SubmissionFilters>) => {
      setView({activeViewId: next.id, filters: next.filters});
      clearSelection();
    },
    [clearSelection]
  );

  const handleSaveView = useCallback(
    (name: string) => {
      const next = save(name, filters);
      setView(prev => ({...prev, activeViewId: next.id}));
    },
    [save, filters]
  );

  const handleFilterChange = useCallback(
    <K extends keyof SubmissionFilters>(
      key: K,
      value: SubmissionFilters[K]
    ) => {
      setView(prev => ({
        activeViewId: null,
        filters: {...prev.filters, [key]: value},
      }));
    },
    []
  );

  const onBulkComplete = useCallback(() => {
    clearSelection();
    refresh();
  }, [clearSelection, refresh]);

  const bulk = useBulkSubmissionActions({
    currentUser,
    isAdmin,
    onComplete: onBulkComplete,
    selected,
    submissions,
  });

  const initialLoading = loading && submissions.length === 0;

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        actions={
          canSubmit && (
            <Button
              onClick={() => setSubmitOpen(true)}
              size="sm"
              variant="brand"
            >
              <Plus className="size-3.5" />
              Submit package
            </Button>
          )
        }
        description="Custom package submissions awaiting review or build."
        title="Submissions"
      />

      {someChecked ? (
        <SubmissionSelectionBar
          count={selected.size}
          isAdmin={isAdmin}
          onAction={bulk.open}
          onClear={clearSelection}
        />
      ) : (
        <SubmissionFilterBar
          activeViewId={activeViewId}
          archOptions={archOptions}
          filters={filters}
          onDeleteView={remove}
          onFilterChange={handleFilterChange}
          onSaveView={handleSaveView}
          onSelectView={handleSelectView}
          repos={repos}
          views={views}
        />
      )}

      {initialLoading ? (
        <Loader animate text="Loading submissions…" />
      ) : filtered.length === 0 ? (
        <EmptyState
          action={
            canSubmit && (
              <Button
                onClick={() => setSubmitOpen(true)}
                size="sm"
                variant="brand"
              >
                <Plus className="size-3.5" />
                Submit package
              </Button>
            )
          }
          description={
            submissions.length === 0
              ? 'Nothing has been submitted yet.'
              : 'No submissions match the current filters.'
          }
          icon={<FileCheck />}
          title={submissions.length === 0 ? 'No submissions' : 'No matches'}
        />
      ) : (
        <ul className="flex flex-col divide-y rounded-lg border">
          <li className="flex items-center gap-3 bg-muted/30 px-4 py-2 text-xs font-medium text-muted-foreground">
            <Checkbox
              aria-label="Select all"
              checked={
                allChecked ? true : someChecked ? 'indeterminate' : false
              }
              onCheckedChange={toggleAll}
            />
            <span>
              {filtered.length} submission{filtered.length === 1 ? '' : 's'}
            </span>
          </li>
          {filtered.map(sub => (
            <SubmissionRow
              key={sub.id}
              onToggle={toggleOne}
              selected={selected.has(sub.id)}
              submission={sub}
            />
          ))}
        </ul>
      )}

      {hasMore && (
        <div
          className="py-2 text-center text-xs text-muted-foreground"
          ref={sentinelRef}
        >
          {loading ? 'Loading more…' : ''}
        </div>
      )}

      <SubmitPackageDialog
        onOpenChange={setSubmitOpen}
        onSuccess={refresh}
        open={submitOpen}
        repos={repos}
      />

      <BulkActionDialog
        action={bulk.action}
        count={bulk.ids.length}
        loading={bulk.loading}
        onConfirm={bulk.run}
        onOpenChange={open => !open && bulk.close()}
      />
    </div>
  );
}
