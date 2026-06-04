'use server';

import {headers} from 'next/headers';
import {redirect} from 'next/navigation';

import {getSession} from '@/app/actions/session';
import {NonNullableUserProfile, UserProfile} from '@/lib/typings';

export async function getFullUserProfile(username: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const [profile, scopes] = await Promise.all([
      cachyBuilderClient.users.getUserProfile(username, await headers()),
      cachyBuilderClient.users.getUserScopes(username, await headers()),
    ]);
    profile.scopes = scopes;
    return profile;
  } catch (error) {
    return {
      error: `Failed to get user profile: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function getUser(username: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const user = await cachyBuilderClient.users.getUserProfile(
      username,
      await headers()
    );
    return user;
  } catch (error) {
    return {
      error: `Failed to get user profile: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function updateProfile(profile: UserProfile, updateAll = false) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const {
      errors,
      profile: updatedProfile,
      validServers,
    } = await cachyBuilderClient.users.updateProfile(
      profile,
      updateAll,
      true,
      await headers()
    );
    session.displayName =
      updatedProfile.display_name ?? updatedProfile.username;
    session.profile_picture_url =
      updatedProfile.profile_picture_url ?? '/cachyos-logo.svg';
    session.username = updatedProfile.username;
    await session.save();
    return {
      profile: updatedProfile,
      success: validServers.length > 0,
      warning:
        errors.length > 0
          ? `Failed to update profile on some servers, you can try again later:\n${errors}`
          : undefined,
    };
  } catch (error) {
    return {
      error: `Failed to update profile: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function updateScopes(
  data: Pick<NonNullableUserProfile, 'scopes' | 'username'>,
  updateAll = false
) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const {errors, validServers} =
      await cachyBuilderClient.users.updateUserScopes(
        data.username,
        data.scopes,
        updateAll,
        await headers()
      );
    return {
      success: validServers.length > 0,
      warning:
        errors.length > 0
          ? `Failed to update scopes on some servers, you can try again later:\n${errors}`
          : undefined,
    };
  } catch (error) {
    return {
      error: `Failed to update scopes: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}
