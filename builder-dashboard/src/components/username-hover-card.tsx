import Link from 'next/link';

import {Avatar, AvatarFallback, AvatarImage} from '@/components/ui/avatar';
import {
  HoverCard,
  HoverCardContent,
  HoverCardTrigger,
} from '@/components/ui/hover-card';

export function UsernameHoverCard({
  description,
  displayName,
  link = false,
  profileImage,
  username,
}: Readonly<{
  description?: null | string;
  displayName?: null | string;
  link?: boolean;
  profileImage?: null | string;
  username: string;
}>) {
  const fallbackName = username
    .split(' ')
    .map(n => n.charAt(0))
    .join('')
    .toUpperCase();
  const avatarUrl = profileImage ?? '/cachyos-logo.svg';

  return (
    <HoverCard>
      <HoverCardTrigger asChild>
        {link ? (
          <Link
            className="font-medium decoration-dotted underline"
            href={`/dashboard/profile/${username}`}
          >
            @{username}
          </Link>
        ) : (
          <span className="font-medium decoration-dotted underline">
            @{username}
          </span>
        )}
      </HoverCardTrigger>
      <HoverCardContent className="max-w-80 w-full shrink flex">
        <div className="flex justify-between gap-4">
          <Avatar className="rounded-lg bg-muted p-1.5 size-20 align-middle">
            <AvatarImage
              alt={displayName ?? username}
              {...(avatarUrl ? {src: avatarUrl} : {})}
            />
            <AvatarFallback className="rounded-lg">
              {fallbackName}
            </AvatarFallback>
          </Avatar>
          <div className="space-y-1 shrink">
            <h4 className="text-sm font-semibold">{displayName ?? username}</h4>
            <p className="text-xs text-muted-foreground">@{username}</p>
            <p className="text-sm">{description}</p>
            {!description && (
              <div className="text-muted-foreground text-sm">
                No profile description available.
              </div>
            )}
          </div>
        </div>
      </HoverCardContent>
    </HoverCard>
  );
}
