import {
  UpdateUserScopesRequestSchema,
  UserProfile,
  UserProfileSchema,
  UserScope,
  userScopeArray,
} from '@/lib/typings';
import {checkScopes} from '@/lib/utils';

import {BaseClient} from './base';
import {multiServerCall, parseOrThrow, requireScopes} from './helpers';

export class UsersClient {
  constructor(private base: BaseClient) {}

  public async getLoggedInUserProfile(clientHeaders = new Headers()) {
    const response = await this.base._fetcher<UserProfile>({
      clientHeaders,
      endpoint: 'user-profile',
    });
    return parseOrThrow(UserProfileSchema, response, 'user profile response');
  }

  public async getUserProfile(username: string, clientHeaders = new Headers()) {
    const response = await this.base._fetcher<UserProfile>({
      clientHeaders,
      endpoint: `profile/${username}`,
    });
    return parseOrThrow(UserProfileSchema, response, 'user profile response');
  }

  public async getUserScopes(username: string, clientHeaders = new Headers()) {
    const {scopes} = this.base.tokens[this.base.serverIndex];
    requireScopes(
      scopes,
      [UserScope.READ, UserScope.ADMIN],
      'view scopes for other users'
    );

    const response = await this.base
      ._fetcher<UserScope[]>({
        clientHeaders,
        endpoint: `profile/${username}/scopes`,
      })
      .catch(() => []);
    return parseOrThrow(userScopeArray, response, 'user scopes response');
  }

  public async updateProfile(
    profile: UserProfile,
    updateAll = false,
    allowInvalid = false,
    clientHeaders = new Headers()
  ) {
    const parsed = parseOrThrow(
      UserProfileSchema,
      profile,
      'user profile request'
    );

    const updateServers = this.base.tokens.filter(
      (s, i) =>
        (updateAll || i === this.base.serverIndex) &&
        !!s.token &&
        checkScopes(s.scopes, [UserScope.READ, UserScope.WRITE])
    );

    if (updateServers.length === 0) {
      throw new Error(
        `No servers to update profile on, you might not have required permissions to update your user profile. Required scopes: ${UserScope.READ},${UserScope.WRITE}`
      );
    }

    const {errors, results} = await multiServerCall<UserProfile>({
      allowInvalid,
      base: this.base,
      clientHeaders,
      label: 'Update User Profile',
      request: {
        endpoint: 'user-profile',
        init: {body: JSON.stringify(parsed), method: 'PUT'},
      },
      schema: UserProfileSchema,
      targets: updateServers,
    });

    const firstOk = results.find(r => r.ok);
    if (!firstOk?.ok) {
      throw new Error(
        `Failed to update user profile on any server:\n${errors}`
      );
    }

    return {
      errors,
      profile: firstOk.data,
      validServers: updateServers.filter((_, i) => results[i].ok),
    };
  }

  public async updateUserScopes(
    username: string,
    scopes: UserScope[],
    updateAll = false,
    clientHeaders = new Headers()
  ) {
    const parsed = parseOrThrow(
      UpdateUserScopesRequestSchema,
      {scopes},
      'update user scopes request'
    );

    const updateServers = this.base.tokens.filter(
      (s, i) =>
        (updateAll || i === this.base.serverIndex) &&
        !!s.token &&
        checkScopes(s.scopes, [UserScope.ADMIN, UserScope.WRITE])
    );

    if (updateServers.length === 0) {
      throw new Error(
        `No servers to update user scopes on, you might not have required permissions to update user scopes. Required scopes: [${UserScope.ADMIN}, ${UserScope.WRITE}]`
      );
    }

    const {errors, results} = await multiServerCall<UserProfile>({
      allowInvalid: false,
      base: this.base,
      clientHeaders,
      label: 'Update User Scopes',
      request: {
        endpoint: `profile/${username}/scopes`,
        init: {body: JSON.stringify(parsed), method: 'PUT'},
      },
      schema: UserProfileSchema,
      targets: updateServers,
    });

    return {
      errors,
      validServers: updateServers.filter((_, i) => results[i].ok),
    };
  }
}
