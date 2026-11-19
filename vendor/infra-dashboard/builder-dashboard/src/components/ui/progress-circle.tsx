// Tremor ProgressCircle [v0.0.3]

import React from 'react';
import {tv, VariantProps} from 'tailwind-variants';

import {cn} from '@/lib/utils';

const progressCircleVariants = tv({
  defaultVariants: {
    variant: 'default',
  },
  slots: {
    background: '',
    circle: '',
  },
  variants: {
    variant: {
      default: {
        background: 'stroke-blue-200 dark:stroke-blue-500/30',
        circle: 'stroke-blue-500 dark:stroke-blue-500',
      },
      error: {
        background: 'stroke-red-200 dark:stroke-red-500/30',
        circle: 'stroke-red-500 dark:stroke-red-500',
      },
      neutral: {
        background: 'stroke-gray-200 dark:stroke-gray-500/40',
        circle: 'stroke-gray-500 dark:stroke-gray-500',
      },
      success: {
        background: 'stroke-green-200 dark:stroke-green-500/30',
        circle: 'stroke-green-500 dark:stroke-green-500',
      },
      warning: {
        background: 'stroke-yellow-200 dark:stroke-yellow-500/30',
        circle: 'stroke-yellow-500 dark:stroke-yellow-500',
      },
    },
  },
});

export type ProgressCircleVariants = ProgressCircleVariantProps['variant'];

interface ProgressCircleProps
  extends
    Omit<React.SVGProps<SVGSVGElement>, 'value'>,
    ProgressCircleVariantProps {
  children?: React.ReactNode;
  max?: number;
  radius?: number;
  showAnimation?: boolean;
  strokeWidth?: number;
  value?: number;
}

type ProgressCircleVariantProps = VariantProps<typeof progressCircleVariants>;

const ProgressCircle = React.forwardRef<SVGSVGElement, ProgressCircleProps>(
  (
    {
      children,
      className,
      max = 100,
      radius = 32,
      showAnimation = true,
      strokeWidth = 6,
      value = 0,
      variant,
      ...props
    }: ProgressCircleProps,
    forwardedRef
  ) => {
    const safeValue = Math.min(max, Math.max(value, 0));
    const normalizedRadius = radius - strokeWidth / 2;
    const circumference = normalizedRadius * 2 * Math.PI;
    const offset = circumference - (safeValue / max) * circumference;

    const {background, circle} = progressCircleVariants({variant});
    return (
      <div
        aria-label="Progress circle"
        aria-valuemax={max}
        aria-valuemin={0}
        aria-valuenow={value}
        className={cn('relative')}
        data-max={max}
        data-value={safeValue ?? null}
        role="progressbar"
      >
        <svg
          className={cn('-rotate-90 transform', className)}
          height={radius * 2}
          ref={forwardedRef}
          viewBox={`0 0 ${radius * 2} ${radius * 2}`}
          width={radius * 2}
          {...props}
        >
          <circle
            className={cn('transition-colors ease-linear', background())}
            cx={radius}
            cy={radius}
            fill="transparent"
            r={normalizedRadius}
            stroke=""
            strokeLinecap="round"
            strokeWidth={strokeWidth}
          />
          {safeValue >= 0 ? (
            <circle
              className={cn(
                'transition-colors ease-linear',
                circle(),
                showAnimation &&
                  'transform-gpu transition-all duration-300 ease-in-out'
              )}
              cx={radius}
              cy={radius}
              fill="transparent"
              r={normalizedRadius}
              stroke=""
              strokeDasharray={`${circumference} ${circumference}`}
              strokeDashoffset={offset}
              strokeLinecap="round"
              strokeWidth={strokeWidth}
            />
          ) : null}
        </svg>
        <div
          className={cn('absolute inset-0 flex items-center justify-center')}
        >
          {children}
        </div>
      </div>
    );
  }
);

ProgressCircle.displayName = 'ProgressCircle';

export {ProgressCircle, type ProgressCircleProps};
