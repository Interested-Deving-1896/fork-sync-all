import type {Metadata, Viewport} from 'next';

import {Geist, Geist_Mono} from 'next/font/google';

import {ThemeProvider} from '@/components/theme-provider';
import {Toaster} from '@/components/ui/sonner';

import './globals.css';

const geistSans = Geist({
  subsets: ['latin'],
  variable: '--font-geist-sans',
});

const geistMono = Geist_Mono({
  subsets: ['latin'],
  variable: '--font-geist-mono',
});

const description =
  process.env.NEXT_PUBLIC_APP_DESCRIPTION ?? 'Builder Dashboard';
const name = process.env.NEXT_PUBLIC_APP_NAME ?? 'Builder Dashboard';

export const viewport: Viewport = {
  colorScheme: 'dark',
  initialScale: 1,
  maximumScale: 1,
  themeColor: '#FFFFFF',
  userScalable: false,
  width: 'device-width',
};

export const metadata: Metadata = {
  applicationName: name,
  description,
  openGraph: {
    description,
    emails: [],
    locale: 'en_US',
    siteName: name,
    title: name,
    type: 'website',
  },
  title: name,
  twitter: {
    description,
    title: name,
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <ThemeProvider attribute="class" defaultTheme="system" enableSystem>
          {children}
          <Toaster duration={5000} />
        </ThemeProvider>
      </body>
    </html>
  );
}
