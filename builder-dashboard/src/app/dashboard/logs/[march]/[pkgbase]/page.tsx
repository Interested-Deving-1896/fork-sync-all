'use client';

import dynamic from 'next/dynamic';
import {useParams} from 'next/navigation';

import Loader from '@/components/loader';
import {PackageMArch, packageMArchValues} from '@/lib/typings';

const TerminalComponent = dynamic(
  () => import('@/components/terminal-component'),
  {
    loading: () => <Loader text="Loading CachyTerm..." />,
    ssr: false,
  }
);

export default function LogsPage() {
  const {march, pkgbase} = useParams<{
    march: PackageMArch;
    pkgbase: string;
  }>();
  if (!march || !pkgbase) {
    return <Loader animate={false} text="Invalid MARCH or PKGBASE" />;
  }
  if (!packageMArchValues.includes(march)) {
    return (
      <Loader
        animate={false}
        text={`Invalid MARCH, valid MARCH: ${packageMArchValues.join(', ')}, got: ${march}`}
      />
    );
  }
  return (
    <div className="h-full w-full flex">
      <TerminalComponent march={march} pkgbase={pkgbase} />
    </div>
  );
}
