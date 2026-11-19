import {SessionOptions} from 'iron-session';

import CachyBuilderClient, {type ServerToken} from '@/lib/api';

export type SessionData = {
  createdAt: number;
  displayName: string;
  isLoggedIn: boolean;
  profile_picture_url: string;
  serverIndex: number;
  tokens: ServerToken[];
  username: string;
};

export const sessionOptions: SessionOptions = {
  cookieName: 'BUILDER_SESSION',
  cookieOptions: {
    secure: process.env.NODE_ENV === 'production',
  },
  password: `${process.env.COOKIE_SECRET}`,
  /**
   * Expire the session after 358 minutes (5 hours and 58 minutes)
   * the cookie will expire after 357 minutes (5 hours and 57 minutes)
   * but the session will be destroyed after 358 minutes (5 hours and 58 minutes).
   */
  ttl: 21480,
};

export const defaultSession: SessionData = {
  createdAt: Date.now(),
  displayName: '',
  isLoggedIn: false,
  profile_picture_url: '/logo.svg',
  serverIndex: CachyBuilderClient.servers.findIndex(s => s.default),
  tokens: CachyBuilderClient.servers.map(s => ({
    description: s.description,
    name: s.name,
    scopes: [],
    token: '',
    url: s.url,
  })),
  username: '',
};
