'use client';

import {
  type RefObject,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import {toast} from 'sonner';

import {ERROR_TOAST_OPTIONS} from '@/lib/toast-action';
import {type ActionError, isActionError} from '@/lib/typings';

interface Page<T> {
  items: T[];
  totalPages: number;
}

interface UseInfiniteListResult<T> {
  error: null | string;
  hasMore: boolean;
  items: T[];
  loading: boolean;
  loadMore: () => void;
  reload: () => void;
  sentinelRef: RefObject<HTMLDivElement | null>;
  totalItems: number;
}

export function useInfiniteList<T>(
  fetchPage: (page: number, pageSize: number) => Promise<ActionError | Page<T>>,
  pageSize = 200
): UseInfiniteListResult<T> {
  const [items, setItems] = useState<T[]>([]);
  const [currentPage, setCurrentPage] = useState(0);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<null | string>(null);
  const reloadKey = useRef(0);
  const sentinelRef = useRef<HTMLDivElement | null>(null);

  const fetchPageRef = useRef(fetchPage);
  useEffect(() => {
    fetchPageRef.current = fetchPage;
  }, [fetchPage]);

  const loadPage = useCallback(
    async (nextPage: number, generation: number) => {
      setLoading(true);
      const result = await fetchPageRef.current(nextPage, pageSize);
      if (reloadKey.current !== generation) return;
      if (isActionError(result)) {
        setError(result.error);
      } else {
        setItems(prev =>
          nextPage === 1 ? result.items : [...prev, ...result.items]
        );
        setTotalPages(result.totalPages);
        setCurrentPage(nextPage);
        setError(null);
      }
      setLoading(false);
    },
    [pageSize]
  );

  const reload = useCallback(() => {
    reloadKey.current += 1;
    setItems([]);
    setCurrentPage(0);
    setTotalPages(1);
    setError(null);
    void loadPage(1, reloadKey.current);
  }, [loadPage]);

  useEffect(() => {
    reload();
  }, [reload]);

  useEffect(() => {
    if (error) {
      toast.error(error, {...ERROR_TOAST_OPTIONS, id: 'infinite-list-error'});
    }
  }, [error]);

  const hasMore = currentPage > 0 && currentPage < totalPages;

  const loadMore = useCallback(() => {
    if (loading || !hasMore) return;
    void loadPage(currentPage + 1, reloadKey.current);
  }, [loading, hasMore, currentPage, loadPage]);

  useEffect(() => {
    const node = sentinelRef.current;
    if (!node || !hasMore) return;
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(e => e.isIntersecting)) loadMore();
      },
      {rootMargin: '200px'}
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [hasMore, loadMore]);

  return useMemo(
    () => ({
      error,
      hasMore,
      items,
      loading,
      loadMore,
      reload,
      sentinelRef,
      totalItems: items.length,
    }),
    [error, hasMore, items, loading, loadMore, reload]
  );
}
