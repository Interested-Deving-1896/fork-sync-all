'use client';

import {useRouter} from 'next/navigation';
import {useEffect, useState} from 'react';

import {syncLoggedInUserScopes} from '@/app/actions/session';
import Loader from '@/components/loader';

export default function Page() {
  const router = useRouter();
  const [status, setStatus] = useState(
    'Builder Dashboard is loading...'
  );
  useEffect(() => {
    let redirectTimeout: null | ReturnType<typeof setTimeout> = null;
    setStatus('Configuring dashboard with your access scopes...');
    syncLoggedInUserScopes()
      .then(data => {
        if (data.error) {
          return setStatus(data.error);
        }
        if (data.success) {
          setStatus(
            data.warning ?? 'Scopes synced successfully. Redirecting...'
          );
          redirectTimeout = setTimeout(() => {
            router.push('/dashboard/package-list');
          }, 1200);
        } else {
          setStatus(
            'Unable to configure scopes for your account. Please contact site administrator.'
          );
        }
      })
      .catch(() => {});
    return () => {
      if (redirectTimeout) clearTimeout(redirectTimeout);
    };
  }, [router]);
  return (
    <div className="flex min-h-svh w-full items-center justify-center p-6 md:p-10">
      <div className="w-full max-w-md">
        <Loader animate text={status} />
      </div>
    </div>
  );
}
