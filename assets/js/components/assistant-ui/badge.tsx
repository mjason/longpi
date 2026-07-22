"use client";

import type { ComponentProps } from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

// Vendored from the assistant-ui registry (base/badge.json) with the official
// variant/size styling kept verbatim. The upstream file renders through
// @base-ui/react's useRender; this project is Radix-based (see CLAUDE.md), so
// it's a plain <span> here — no render-prop polymorphism needed.
const badgeVariants = cva(
  "inline-flex items-center justify-center gap-1 rounded-md text-xs font-medium transition-colors [&_svg]:size-3 [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        outline:
          "border-input text-muted-foreground [a&]:hover:bg-accent [a&]:hover:text-accent-foreground border bg-transparent",
        secondary:
          "bg-secondary text-secondary-foreground [a&]:hover:bg-secondary/80",
        muted:
          "bg-muted text-muted-foreground [a&]:hover:bg-muted/80 [a&]:hover:text-foreground",
        ghost:
          "text-muted-foreground [a&]:hover:bg-accent [a&]:hover:text-accent-foreground bg-transparent",
        info: "bg-blue-100 text-blue-700 dark:bg-blue-900/50 dark:text-blue-300 [a&]:hover:bg-blue-100/80",
        warning:
          "bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-300 [a&]:hover:bg-amber-100/80",
        success:
          "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/50 dark:text-emerald-300 [a&]:hover:bg-emerald-100/80",
        destructive:
          "bg-red-100 text-red-700 dark:bg-red-900/50 dark:text-red-300 [a&]:hover:bg-red-100/80",
      },
      size: {
        sm: "px-1.5 py-0.5",
        default: "px-2 py-1",
        lg: "px-2.5 py-1.5 text-sm",
      },
    },
    defaultVariants: {
      variant: "outline",
      size: "default",
    },
  },
);

export type BadgeProps = ComponentProps<"span"> & VariantProps<typeof badgeVariants>;

function Badge({ className, variant, size, ...props }: BadgeProps) {
  return (
    <span
      data-slot="badge"
      data-variant={variant}
      data-size={size}
      className={cn(badgeVariants({ variant, size }), className)}
      {...props}
    />
  );
}

export { Badge, badgeVariants };
