'use server';

import {getIronSession} from 'iron-session';
import {cookies, headers} from 'next/headers';
import {redirect} from 'next/navigation';

import CachyBuilderClient from '@/lib/api';
import {isAccessibleToken} from '@/lib/api/base';
import {defaultSession, SessionData, sessionOptions} from '@/lib/session';
import {
  LoginRequest,
  LoginRequestSchema,
  UserData,
  UserProfile,
} from '@/lib/typings';

export async function changeServer(serverName: string) {
  const {session} = await getSession();
  const serverIndex = session.tokens.findIndex(
    token => token.name === serverName && token.token !== ''
  );
  if (serverIndex === -1) {
    return {
      error: `Server "${serverName}" not found or is not accessible with the current session.`,
    };
  }
  session.serverIndex = serverIndex;
  await session.save();
  return {
    msg: `Switched to server "${serverName}" successfully.`,
  };
}

export async function getAccessibleServers() {
  const {session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  return session.tokens.map((token, index) => ({
    accessible: isAccessibleToken(token),
    active: index === session.serverIndex,
    description: token.description,
    name: token.name,
  }));
}

export async function getLoggedInUser(
  fullProfile: false
): Promise<UserData | {error: string}>;
export async function getLoggedInUser(
  fullProfile: true
): Promise<UserProfile | {error: string}>;
export async function getLoggedInUser(fullProfile = false) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const user = await cachyBuilderClient.users.getLoggedInUserProfile(
      await headers()
    );
    session.displayName = user.display_name ?? user.username;
    session.username = user.username;
    session.profile_picture_url =
      user.profile_picture_url ?? '/logo.svg';
    await session.save();
    if (fullProfile) {
      user.scopes = session.tokens[session.serverIndex].scopes;
      return user;
    }
    return {
      displayName: session.displayName,
      profile_picture_url: session.profile_picture_url,
      scopes: session.tokens[session.serverIndex].scopes,
      username: session.username,
    };
  } catch (error) {
    return {
      error: `Failed to get user profile: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function getSession() {
  const session = await getIronSession<SessionData>(
    await cookies(),
    sessionOptions
  );
  if (!session.isLoggedIn) {
    session.displayName = defaultSession.displayName;
    session.isLoggedIn = defaultSession.isLoggedIn;
    session.tokens = defaultSession.tokens;
    session.createdAt = Date.now();
    session.serverIndex = defaultSession.serverIndex;
  }
  const cachyBuilderClient = new CachyBuilderClient(
    session.serverIndex,
    session.tokens
  );
  return {
    cachyBuilderClient,
    session,
  };
}

export async function isLoggedIn() {
  const {session} = await getSession();
  return session.isLoggedIn;
}

export async function login(loginRequest: LoginRequest) {
  const data = LoginRequestSchema.safeParse(loginRequest);
  if (!data.success) {
    return {
      error: `Invalid login request: ${data.error.issues.map(issue => issue.message).join(', ')}`,
    };
  }

  const turnstileResponse = await fetch(
    'https://challenges.cloudflare.com/turnstile/v0/siteverify',
    {
      body: `secret=${encodeURIComponent(process.env.TURNSTILE_SECRET_KEY!)}&response=${encodeURIComponent(data.data.turnstileToken)}`,
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
      },
      method: 'POST',
    }
  )
    .then(res => res.json())
    .then(res => res.success)
    .catch(() => false);

  if (!turnstileResponse) {
    return {
      error: 'Turnstile verification failed. Please try again.',
    };
  }

  const {cachyBuilderClient, session} = await getSession();
  try {
    const {errors, validServers} = await cachyBuilderClient.login(
      data.data,
      await headers(),
      true
    );
    session.isLoggedIn = true;
    session.username = data.data.username;
    session.tokens = cachyBuilderClient.apiTokens;
    session.serverIndex = cachyBuilderClient.serverIdx;
    session.profile_picture_url = '/logo.svg';
    await session.save();
    return {
      success: validServers.length > 0,
      warning:
        errors.length > 0
          ? `Some servers failed to respond correctly and have been disabled for this session:\n${errors}`
          : undefined,
    };
  } catch (error) {
    return {
      error: `Login failed: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function logout() {
  const {session} = await getSession();
  session.destroy();
  return redirect('/');
}

export async function retryServerAccess(serverName: string) {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const {tokens, unreachable} =
      await cachyBuilderClient.syncLoggedInUserScopes(
        true,
        await headers(),
        serverName
      );
    if (unreachable.includes(serverName)) {
      return {
        error: `Server "${serverName}" is still unreachable. The builder API may be down or your token has expired.`,
      };
    }
    session.tokens = tokens;
    await session.save();
    return {msg: `Restored access to "${serverName}".`};
  } catch (error) {
    return {
      error: `Failed to retry access for "${serverName}": ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}

export async function syncLoggedInUserScopes() {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const {tokens, unreachable} =
      await cachyBuilderClient.syncLoggedInUserScopes(true, await headers());
    session.tokens = tokens;
    await session.save();
    return {
      success: tokens.some(isAccessibleToken),
      unreachable,
      warning:
        unreachable.length > 0
          ? `Could not validate access on: ${unreachable.join(', ')}. You can retry per server from the sidebar switcher.`
          : undefined,
    };
  } catch (error) {
    return {
      error: `Failed to sync user scopes: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}
