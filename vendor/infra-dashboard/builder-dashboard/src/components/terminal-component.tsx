'use client';

import {FitAddon} from '@xterm/addon-fit';
import {SearchAddon} from '@xterm/addon-search';
import {WebLinksAddon} from '@xterm/addon-web-links';
import {WebglAddon} from '@xterm/addon-webgl';
import {Terminal} from '@xterm/xterm';
import styles from 'ansi-styles';
import {ArrowDownIcon, ArrowUpIcon} from 'lucide-react';
import {useCallback, useEffect, useMemo, useRef, useState} from 'react';

import {getPackageLog} from '@/app/actions/packages';
import Loader from '@/components/loader';
import {Input} from '@/components/ui/input';
import {useGenericShortcutListener} from '@/hooks/use-keyboard-shortcut-listener';
import {PackageMArch} from '@/lib/typings';

import '@xterm/xterm/css/xterm.css';

const OSC = '\u001B]';
const BEL = '\u0007';
const SEP = ';';

export default function TerminalComponent({
  march,
  pkgbase,
}: Readonly<{
  march: PackageMArch;
  pkgbase: string;
}>) {
  const [loaded, setLoaded] = useState(false);
  const [textLoaded, setTextLoaded] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const arrowUpRef = useRef<HTMLDivElement>(null);
  const arrowDownRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const webLinksAddon = useMemo(() => new WebLinksAddon(), []);
  const searchAddon = useMemo(() => new SearchAddon(), []);
  const fitAddon = useMemo(() => new FitAddon(), []);
  const webglAddon = useMemo(() => new WebglAddon(), []);
  const terminal = useMemo(() => {
    const term = new Terminal({
      allowProposedApi: true,
      convertEol: true,
      cursorBlink: true,
      cursorInactiveStyle: 'underline',
      cursorStyle: 'underline',
      disableStdin: true,
      fontFamily: 'JetBrains Mono, monospace',
      scrollback: Number.MAX_SAFE_INTEGER,
      theme: {
        background: '#000000',
        black: '#1f1f1f',
        blue: '#2a84d2',
        brightBlack: '#d6dae4',
        brightBlue: '#0f80d5',
        brightCyan: '#0f7cda',
        brightGreen: '#1dd260',
        brightMagenta: '#524fb9',
        brightRed: '#de342e',
        brightWhite: '#ffffff',
        brightYellow: '#f2bd09',
        cursor: '#b9b9b9',
        cyan: '#0f80d5',
        foreground: '#d6dae4',
        green: '#2cc55d',
        magenta: '#4e59b7',
        red: '#f71118',
        selectionBackground: '#b9b9b9',
        selectionForeground: '#131313',
        white: '#d6dae4',
        yellow: '#ecb90f',
      },
    });
    term.loadAddon(webLinksAddon);
    term.loadAddon(searchAddon);
    term.loadAddon(fitAddon);
    term.loadAddon(webglAddon);
    return term;
  }, [fitAddon, searchAddon, webLinksAddon, webglAddon]);
  const searchEvent = useCallback(() => {
    searchAddon.findNext(inputRef.current?.value ?? '', {
      caseSensitive: false,
      decorations: {
        activeMatchColorOverviewRuler: '#f97316',
        matchBackground: '#f97316',
        matchOverviewRuler: '#f97316',
      },
      incremental: false,
      wholeWord: false,
    });
  }, [searchAddon]);
  const arrowUpEvent = useCallback(() => {
    searchAddon.findPrevious(inputRef.current?.value ?? '', {
      caseSensitive: false,
      incremental: false,
      wholeWord: false,
    });
  }, [searchAddon]);
  useEffect(() => {
    const input = inputRef.current;
    const arrowUp = arrowUpRef.current;
    const arrowDown = arrowDownRef.current;
    if (!loaded && ref.current && input && arrowUp && arrowDown) {
      setLoaded(true);
      terminal.open(ref.current);
      terminal.attachCustomKeyEventHandler(e => {
        if (e.key === 'f' && e.ctrlKey) {
          containerRef.current?.classList.remove('md:hidden');
          inputRef.current?.focus();
          return false;
        }
        return true;
      });
      terminal.attachCustomKeyEventHandler(arg => {
        if (arg.ctrlKey && arg.code === 'KeyC' && arg.type === 'keydown') {
          const selection = terminal.getSelection();
          if (selection) {
            navigator.clipboard.writeText(selection);
            return false;
          }
        }
        return true;
      });
      getPackageLog(pkgbase, march, true).then(log => {
        if (typeof log === 'object' && 'error' in log) {
          terminal.write(
            `${styles.redBright.open}Error: ${log.error}${styles.redBright.close}\n`
          );
          setTextLoaded(true);
          fitAddon.fit();
          inputRef.current?.addEventListener('input', searchEvent);
          arrowUpRef.current?.addEventListener('click', arrowUpEvent);
          arrowDownRef.current?.addEventListener('click', searchEvent);
          return;
        }
        terminal.write(
          log
            .replaceAll(
              /\bERROR\b/gi,
              `${styles.redBright.open}$&${styles.redBright.close}`
            )
            .replaceAll(
              /\bWARN(ING)?\b/gi,
              `${styles.yellowBright.open}$&${styles.yellowBright.close}`
            )
            .replaceAll(
              /\bcommand not found.*/gi,
              `${styles.redBright.open}$&${styles.redBright.close}`
            )
            .replaceAll(
              /\b[A-Fa-f0-9]{16}\b|\b[A-Fa-f0-9]{40}\b/g,
              [
                OSC,
                '8',
                SEP,
                SEP,
                'https://keyserver.ubuntu.com/pks/lookup?search=$&&fingerprint=on&op=index',
                BEL,
                '$&',
                OSC,
                '8',
                SEP,
                SEP,
                BEL,
              ].join('')
            ) ??
            `${styles.yellowBright.open}No logs found for this package (Received a blank response).${styles.yellowBright.close}`,
          () => {
            setTextLoaded(true);
            fitAddon.fit();
            inputRef.current?.addEventListener('input', searchEvent);
            arrowUpRef.current?.addEventListener('click', arrowUpEvent);
            arrowDownRef.current?.addEventListener('click', searchEvent);
          }
        );
      });
    }
    return () => {
      if (loaded) {
        fitAddon.dispose();
        searchAddon.dispose();
        webLinksAddon.dispose();
        webglAddon.dispose();
        terminal.dispose();
        input?.removeEventListener('input', searchEvent);
        arrowUp?.removeEventListener('click', arrowUpEvent);
        arrowDown?.removeEventListener('click', searchEvent);
      }
    };
  }, [
    ref,
    loaded,
    inputRef,
    arrowUpRef,
    arrowDownRef,
    terminal,
    pkgbase,
    march,
    fitAddon,
    searchEvent,
    arrowUpEvent,
    searchAddon,
    webLinksAddon,
    webglAddon,
  ]);
  useGenericShortcutListener('f', () => {
    containerRef.current?.classList.remove('md:hidden');
    inputRef.current?.focus();
  });
  return (
    <div className="flex flex-col w-full">
      <div hidden={!!textLoaded}>
        <Loader text="Processing the log file..." />
      </div>
      <div className="md:hidden" ref={containerRef}>
        <Input
          className="absolute z-10 max-w-xl right-0"
          placeholder="Search logs"
          ref={inputRef}
        />
        <div ref={arrowUpRef}>
          <ArrowUpIcon className="absolute z-10 right-10 mt-2 dark:hover:bg-gray-50/25 hover:bg-gray-400/50 rounded text-tremor-content dark:text-white" />
        </div>
        <div ref={arrowDownRef}>
          <ArrowDownIcon className="absolute z-10 right-5 mt-2 dark:hover:bg-gray-50/25 hover:bg-gray-400/50 rounded text-tremor-content dark:text-white" />
        </div>
      </div>
      <div
        className="h-full flex flex-col grow min-h-screen w-full"
        ref={ref}
      />
    </div>
  );
}
