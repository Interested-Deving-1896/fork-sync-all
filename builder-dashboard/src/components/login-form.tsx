'use client';

import {zodResolver} from '@hookform/resolvers/zod';
import {Turnstile} from '@marsidev/react-turnstile';
import Image from 'next/image';
import {useRouter} from 'next/navigation';
import {useCallback, useEffect, useState} from 'react';
import {useForm} from 'react-hook-form';
import {toast} from 'sonner';

import {isLoggedIn, login} from '@/app/actions/session';
import {Button} from '@/components/ui/button';
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card';
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import {Input} from '@/components/ui/input';
import {LoginRequest, LoginRequestSchema} from '@/lib/typings';
import {cn} from '@/lib/utils';

export function LoginForm({className, ...props}: React.ComponentProps<'div'>) {
  const router = useRouter();
  const [error, setError] = useState<null | string>(null);
  const [warning, setWarning] = useState<null | string>(null);
  const [submitting, setSubmitting] = useState(false);
  const [canRedirect, setCanRedirect] = useState(false);
  useEffect(() => {
    isLoggedIn().then(redirect => {
      if (redirect) {
        router.push('/dashboard/package-list');
      }
    });
  }, [router]);
  const form = useForm<LoginRequest>({
    defaultValues: {
      password: '',
      turnstileToken: '',
      username: '',
    },
    resolver: zodResolver(LoginRequestSchema),
  });
  const onSubmit = useCallback(
    (data: LoginRequest) => {
      if (submitting) {
        return;
      }
      setSubmitting(true);
      setCanRedirect(false);
      setError(null);
      setWarning(null);
      const toastId = toast.loading('Logging in...');
      login(data)
        .then(res => {
          if (res.error) {
            setError(res.error);
            toast.error('Failed to login with provided credentials', {
              closeButton: true,
              duration: Infinity,
              id: toastId,
            });
          } else if (res.warning) {
            setWarning(res.warning);
            toast.warning(
              'Some servers are not accessible with provided credentials',
              {
                closeButton: true,
                duration: Infinity,
                id: toastId,
              }
            );
            setCanRedirect(true);
          } else {
            toast.success('Login successful!', {id: toastId});
            setCanRedirect(true);
            router.push('/validate');
          }
        })
        .catch(() => {
          setError('An unexpected error occurred while logging in.');
          toast.error('An unexpected error occurred while logging in.', {
            closeButton: true,
            duration: Infinity,
            id: toastId,
          });
        })
        .finally(() => {
          setSubmitting(false);
        });
    },
    [submitting, router]
  );
  return (
    <div className={cn('flex flex-col gap-6', className)} {...props}>
      <Card className="relative overflow-hidden">
        <CardHeader>
          <Image
            alt="Logo"
            className="invert dark:invert-0 mx-auto mb-4"
            height={128}
            src="/logo-white.svg"
            width={128}
          />
          <CardTitle className="text-center">
            Login to your Builder account
          </CardTitle>
          <CardDescription>
            Enter your email and password to access the Builder Dashboard.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmit)}>
              <div className="flex flex-col gap-6">
                <div className="grid gap-3">
                  <FormField
                    control={form.control}
                    name="username"
                    render={({field}) => (
                      <FormItem>
                        <FormLabel>Username</FormLabel>
                        <FormControl>
                          <Input {...field} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                <div className="grid gap-3">
                  <FormField
                    control={form.control}
                    name="password"
                    render={({field}) => (
                      <FormItem>
                        <FormLabel>Password</FormLabel>
                        <FormControl>
                          <Input type="password" {...field} />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                <div className="grid gap-3">
                  <FormField
                    control={form.control}
                    name="turnstileToken"
                    render={({field}) => (
                      <FormItem>
                        <FormLabel>Are you a robot?</FormLabel>
                        <FormControl>
                          <Turnstile
                            className="w-full"
                            onError={() => {
                              field.onChange('');
                            }}
                            onExpire={() => {
                              field.onChange('');
                            }}
                            onSuccess={token => {
                              field.onChange(token);
                            }}
                            onTimeout={() => {
                              field.onChange('');
                            }}
                            options={{
                              appearance: 'always',
                              size: 'flexible',
                              theme: 'auto',
                            }}
                            siteKey={
                              process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY!
                            }
                            {...field}
                          />
                        </FormControl>
                        <FormMessage />
                      </FormItem>
                    )}
                  />
                </div>
                {error && (
                  <div className="mt-4 text-center text-sm text-destructive whitespace-pre-line">
                    {error}
                  </div>
                )}
                {warning && (
                  <div className="mt-4 text-center text-sm text-amber-400 whitespace-pre-line">
                    {warning}
                  </div>
                )}
                <div className="flex flex-col gap-3">
                  {canRedirect ? (
                    <Button
                      className="w-full"
                      disabled={submitting || (canRedirect && !warning)}
                      onClick={e => {
                        e.preventDefault();
                        router.push('/validate');
                      }}
                      type="submit"
                    >
                      {warning
                        ? 'Continue with warning'
                        : 'Logged in, redirecting...'}
                    </Button>
                  ) : (
                    <Button
                      className="w-full"
                      disabled={submitting || canRedirect}
                      type="submit"
                    >
                      {submitting ? 'Logging in...' : 'Login'}
                    </Button>
                  )}
                </div>
              </div>
              <div className="mt-4 text-center text-sm text-muted-foreground">
                By signing in, you agree to data processing and privacy policy.
                Your ip address and user agent will be stored for security
                purposes.
              </div>
            </form>
          </Form>
        </CardContent>
      </Card>
    </div>
  );
}
