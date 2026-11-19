'use client';

import {Search} from 'lucide-react';

import type {SavedView} from '@/lib/saved-views';

import {labelFor} from '@/components/custom/submission-status';
import {FilterToolbar} from '@/components/ui/filter-toolbar';
import {Input} from '@/components/ui/input';
import {SavedViews} from '@/components/ui/saved-views';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {type CustomRepo, SubmissionStatus} from '@/lib/typings';

import type {SubmissionFilters} from './_types';

interface SubmissionFilterBarProps {
  activeViewId: null | string;
  archOptions: ReadonlyArray<string>;
  filters: SubmissionFilters;
  onDeleteView: (id: string) => void;
  onFilterChange: <K extends keyof SubmissionFilters>(
    key: K,
    value: SubmissionFilters[K]
  ) => void;
  onSaveView: (name: string) => void;
  onSelectView: (view: SavedView<SubmissionFilters>) => void;
  repos: ReadonlyArray<CustomRepo>;
  views: ReadonlyArray<SavedView<SubmissionFilters>>;
}

export function SubmissionFilterBar({
  activeViewId,
  archOptions,
  filters,
  onDeleteView,
  onFilterChange,
  onSaveView,
  onSelectView,
  repos,
  views,
}: SubmissionFilterBarProps) {
  return (
    <FilterToolbar>
      <div className="relative w-full max-w-sm">
        <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-muted-foreground" />
        <Input
          className="h-8 pl-8"
          onChange={e => onFilterChange('search', e.target.value)}
          placeholder="Search pkgbase, repo, submitter…"
          value={filters.search}
        />
      </div>
      <div className="ml-auto flex items-center gap-2">
        <Select
          onValueChange={v => onFilterChange('status', v)}
          value={filters.status}
        >
          <SelectTrigger className="h-8 w-[160px]">
            <SelectValue placeholder="Status" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="ALL">All statuses</SelectItem>
            {Object.values(SubmissionStatus).map(s => (
              <SelectItem key={s} value={s}>
                {labelFor(s)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select
          onValueChange={v => onFilterChange('repo', v)}
          value={filters.repo}
        >
          <SelectTrigger className="h-8 w-[140px]">
            <SelectValue placeholder="Repo" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="ALL">All repos</SelectItem>
            {repos.map(r => (
              <SelectItem key={r.id} value={r.repo_name}>
                {r.repo_name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select
          onValueChange={v => onFilterChange('arch', v)}
          value={filters.arch}
        >
          <SelectTrigger className="h-8 w-[140px]">
            <SelectValue placeholder="Architecture" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="ALL">All architectures</SelectItem>
            {archOptions.map(a => (
              <SelectItem key={a} value={a}>
                {a}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <SavedViews
          activeId={activeViewId}
          onDelete={onDeleteView}
          onSave={onSaveView}
          onSelect={onSelectView}
          views={views}
        />
      </div>
    </FilterToolbar>
  );
}
