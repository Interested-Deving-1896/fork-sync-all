import {redirect} from 'next/navigation';

export default function CustomIndexPage() {
  redirect('/dashboard/custom/repos');
}
