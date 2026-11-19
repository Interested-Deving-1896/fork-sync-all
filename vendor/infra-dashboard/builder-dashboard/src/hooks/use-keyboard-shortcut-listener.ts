'use client';

import {useEffect, useState} from 'react';

const numericKeyRegex = /^\d$/;

export function useGenericShortcutListener(
  key: string,
  callback: () => void,
  ignoreModifiers = false
) {
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!event.key) return;
      if (
        (event.ctrlKey || event.metaKey || ignoreModifiers) &&
        event.key.toLowerCase() === key.toLowerCase()
      ) {
        event.preventDefault();
        callback();
      }
    };

    globalThis.addEventListener('keydown', handleKeyDown);

    return () => {
      globalThis.removeEventListener('keydown', handleKeyDown);
    };
  });
}

export function useGenericVimShortcutListener(
  key: string,
  callback: () => void
) {
  const [colonAndKeyPressed, setColonAndKeyPressed] = useState(false);

  useEffect(() => {
    let timer: NodeJS.Timeout | undefined;
    let colonPressed = false;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!event.key) return;
      if (event.key === ':') {
        colonPressed = true;
        timer = setTimeout(() => {
          colonPressed = false;
        }, 800);
      } else if (
        colonPressed &&
        event.key.toLowerCase() === key.toLowerCase()
      ) {
        setColonAndKeyPressed(true);
        colonPressed = false;
        clearTimeout(timer);
      } else {
        colonPressed = false;
        clearTimeout(timer);
      }
    };

    globalThis.addEventListener('keydown', handleKeyDown);

    return () => {
      globalThis.removeEventListener('keydown', handleKeyDown);
      clearTimeout(timer);
    };
  }, [key]);

  useEffect(() => {
    if (colonAndKeyPressed) {
      callback();
      setColonAndKeyPressed(false);
    }
  }, [callback, colonAndKeyPressed]);
}

export function useNumericKeyShortcutListener(callback: (key: number) => void) {
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!event.key) return;
      const key = event.key.toLowerCase();
      if ((event.ctrlKey || event.metaKey) && numericKeyRegex.test(key)) {
        event.preventDefault();
        callback(Number.parseInt(key, 10));
      }
    };

    globalThis.addEventListener('keydown', handleKeyDown);

    return () => {
      globalThis.removeEventListener('keydown', handleKeyDown);
    };
  });
}

export function useNumericKeyVimShortcutListener(
  callback: (key: number) => void
) {
  const [colonAndKeyPressed, setColonAndKeyPressed] = useState<null | number>(
    null
  );

  useEffect(() => {
    let timer: NodeJS.Timeout | undefined;
    let colonPressed = false;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!event.key) return;
      const key = event.key.toLowerCase();
      if (key === ':') {
        colonPressed = true;
        timer = setTimeout(() => {
          colonPressed = false;
        }, 800);
      } else if (colonPressed && numericKeyRegex.test(key)) {
        setColonAndKeyPressed(Number.parseInt(key, 10));
        colonPressed = false;
        clearTimeout(timer);
      } else {
        colonPressed = false;
        clearTimeout(timer);
      }
    };

    globalThis.addEventListener('keydown', handleKeyDown);

    return () => {
      globalThis.removeEventListener('keydown', handleKeyDown);
      clearTimeout(timer);
    };
  }, []);

  useEffect(() => {
    if (colonAndKeyPressed) {
      callback(colonAndKeyPressed);
      setColonAndKeyPressed(null);
    }
  }, [callback, colonAndKeyPressed]);
}
