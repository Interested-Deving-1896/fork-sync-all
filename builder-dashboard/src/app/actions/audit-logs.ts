'use server';

import {headers} from 'next/headers';
import {redirect} from 'next/navigation';

import {getSession} from '@/app/actions/session';
import {BasePackageListSchema, ParsedAuditLogEntry} from '@/lib/typings';

export async function getAuditLogs() {
  const {cachyBuilderClient, session} = await getSession();
  if (!session.isLoggedIn) {
    return redirect('/');
  }
  try {
    const logs = await cachyBuilderClient.auditLogs.getAuditLogs(
      await headers()
    );
    return logs.map(item => {
      const description = item.event_desc;
      const packages: ParsedAuditLogEntry[] = [];
      if (description.startsWith('rebuild queued')) {
        const [pkgbase, repository, march] = description
          .replace('rebuild queued ', '')
          .split("'-'")
          .map(part => part.replaceAll("'", '').trim());
        packages.push({
          description: `Package Base: ${pkgbase}, Repository: ${repository}, MArch: ${march}`,
          id: `${item.id}-1`,
          updated: item.updated,
          username: item.username,
        });
      } else if (description.startsWith('bulk rebuild queued:')) {
        const packagesString = description
          .replace('bulk rebuild queued: ', '')
          .replaceAll("'", '')
          .trim();
        const packagesArray = BasePackageListSchema.safeParse(
          JSON.parse(packagesString)
        );
        if (packagesArray.success) {
          let i = 0;
          for (const pkg of packagesArray.data) {
            packages.push({
              description: `Package Base: ${pkg.pkgbase}, Repository: ${pkg.repository}, MArch: ${pkg.march}`,
              id: `${item.id}-${++i}`,
              updated: item.updated,
              username: item.username,
            });
          }
        }
      }
      return {
        description:
          packages.length > 1
            ? `Bulk Rebuild: ${packages.length} packages`
            : packages.length === 1
              ? packages.shift()!.description
              : description,
        eventName: item.event_name,
        id: item.id,
        packages,
        updated: item.updated,
        username: item.username,
      };
    });
  } catch (error) {
    return {
      error: `Failed to get audit logs: ${error instanceof Error ? error.message : 'Unknown error'}`,
    };
  }
}
