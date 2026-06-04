'use client';

import {Bookmark, BookmarkPlus, Check, Trash2} from 'lucide-react';
import {useState} from 'react';

import type {SavedView} from '@/lib/saved-views';

import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {Input} from '@/components/ui/input';
import {Label} from '@/components/ui/label';

interface SavedViewsProps<F> {
  activeId: null | string;
  onDelete?: (id: string) => void;
  onSave: (name: string) => void;
  onSelect: (view: SavedView<F>) => void;
  views: ReadonlyArray<SavedView<F>>;
}

export function SavedViews<F>({
  activeId,
  onDelete,
  onSave,
  onSelect,
  views,
}: SavedViewsProps<F>) {
  const [saveOpen, setSaveOpen] = useState(false);
  const [name, setName] = useState('');

  const builtins = views.filter(v => v.builtin);
  const userViews = views.filter(v => !v.builtin);
  const activeName = views.find(v => v.id === activeId)?.name;

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button size="sm" variant="outline">
            <Bookmark className="size-3.5" />
            {activeName ?? 'Views'}
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-56">
          {builtins.length > 0 && (
            <>
              <DropdownMenuLabel className="text-xs text-muted-foreground">
                Built-in
              </DropdownMenuLabel>
              <DropdownMenuGroup>
                {builtins.map(view => (
                  <DropdownMenuItem
                    key={view.id}
                    onSelect={() => onSelect(view)}
                  >
                    {view.id === activeId ? (
                      <Check className="size-3.5" />
                    ) : (
                      <span className="size-3.5" />
                    )}
                    {view.name}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuGroup>
              <DropdownMenuSeparator />
            </>
          )}
          {userViews.length > 0 && (
            <>
              <DropdownMenuLabel className="text-xs text-muted-foreground">
                Saved
              </DropdownMenuLabel>
              <DropdownMenuGroup>
                {userViews.map(view => (
                  <DropdownMenuItem
                    className="group"
                    key={view.id}
                    onSelect={() => onSelect(view)}
                  >
                    {view.id === activeId ? (
                      <Check className="size-3.5" />
                    ) : (
                      <span className="size-3.5" />
                    )}
                    <span className="flex-1 truncate">{view.name}</span>
                    {onDelete && (
                      <button
                        aria-label={`Delete view ${view.name}`}
                        className="ml-1 text-muted-foreground opacity-0 group-hover:opacity-100 hover:text-destructive"
                        onClick={e => {
                          e.stopPropagation();
                          onDelete(view.id);
                        }}
                        type="button"
                      >
                        <Trash2 className="size-3.5" />
                      </button>
                    )}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuGroup>
              <DropdownMenuSeparator />
            </>
          )}
          <DropdownMenuItem
            onSelect={() => {
              setName('');
              setSaveOpen(true);
            }}
          >
            <BookmarkPlus className="size-3.5" />
            Save current view…
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      <Dialog onOpenChange={setSaveOpen} open={saveOpen}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Save view</DialogTitle>
          </DialogHeader>
          <div className="flex flex-col gap-2 py-2">
            <Label htmlFor="view-name">Name</Label>
            <Input
              autoFocus
              id="view-name"
              onChange={e => setName(e.target.value)}
              placeholder="My pending reviews"
              value={name}
            />
          </div>
          <DialogFooter>
            <DialogClose asChild>
              <Button variant="outline">Cancel</Button>
            </DialogClose>
            <Button
              disabled={!name.trim()}
              onClick={() => {
                onSave(name.trim());
                setSaveOpen(false);
              }}
              variant="brand"
            >
              Save
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
