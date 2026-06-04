'use client';
import {useParams, useRouter} from 'next/navigation';
import {useEffect, useState} from 'react';
import {toast} from 'sonner';

import {getLoggedInUser} from '@/app/actions/session';
import {getFullUserProfile, getUser} from '@/app/actions/users';
import Loader from '@/components/loader';
import {Card} from '@/components/ui/card';
import {useSidebar} from '@/components/ui/sidebar';
import {UserProfileForm} from '@/components/user-profile-form';
import {UserProfile, UserScope} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

export default function UserProfilePage() {
  const router = useRouter();
  const {username} = useParams<{username: string}>();
  const {activeServer, scopes} = useSidebar();
  const [user, setUser] = useState<null | UserProfile>(null);

  useEffect(() => {
    // TODO: Extract into global app state to avoid refetching.
    getLoggedInUser(false).then(data => {
      if ('error' in data) {
        toast.error(data.error, {
          closeButton: true,
          duration: Infinity,
        });
      } else if (username === data.username) {
        router.replace('/dashboard/profile');
      }
    });
  }, [username, router]);

  const enableScopes = checkScopes(scopes, [UserScope.ADMIN, UserScope.WRITE]);

  useEffect(() => {
    if (!username) {
      return;
    }
    setUser(null);
    (enableScopes ? getFullUserProfile(username) : getUser(username)).then(
      data => {
        if ('error' in data) {
          toast.error(data.error, {
            closeButton: true,
            duration: Infinity,
          });
        } else {
          setUser(data);
        }
      }
    );
  }, [activeServer, username, enableScopes]);

  return (
    <Card className="flex min-h-full w-full items-center justify-center p-6 md:p-10">
      <div className="w-full max-w-lg">
        {user ? (
          <UserProfileForm canEditScopes={enableScopes} user={user} />
        ) : (
          <Loader animate text="Loading user profile..." />
        )}
      </div>
    </Card>
  );
}
