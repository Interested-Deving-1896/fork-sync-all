'use client';

import {useCallback, useEffect, useState} from 'react';

export interface SavedView<F> {
  builtin?: boolean;
  filters: F;
  id: string;
  name: string;
}

export function useSavedViews<F>(
  storageKey: string,
  builtins: SavedView<F>[] = []
) {
  const [userViews, setUserViews] = useState<SavedView<F>[]>([]);

  useEffect(() => {
    setUserViews(readStorage<F>(storageKey));
  }, [storageKey]);

  const persist = useCallback(
    (next: SavedView<F>[]) => {
      setUserViews(next);
      writeStorage(storageKey, next);
    },
    [storageKey]
  );

  const save = useCallback(
    (name: string, filters: F) => {
      const next: SavedView<F> = {
        filters,
        id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
        name,
      };
      persist([...userViews, next]);
      return next;
    },
    [userViews, persist]
  );

  const remove = useCallback(
    (id: string) => {
      persist(userViews.filter(v => v.id !== id));
    },
    [userViews, persist]
  );

  const rename = useCallback(
    (id: string, name: string) => {
      persist(userViews.map(v => (v.id === id ? {...v, name} : v)));
    },
    [userViews, persist]
  );

  return {
    builtins,
    remove,
    rename,
    save,
    userViews,
    views: [...builtins, ...userViews],
  };
}

function readStorage<F>(key: string): SavedView<F>[] {
  if (typeof window === 'undefined') return [];
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as SavedView<F>[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeStorage<F>(key: string, views: SavedView<F>[]) {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(key, JSON.stringify(views));
  } catch {
    // ignore quota errors
  }
}
