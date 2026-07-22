import { Tooltip as TooltipPrimitive } from "radix-ui";
import * as React from "react";
import { cn } from "../../lib/utils";

const TooltipProvider = TooltipPrimitive.Provider;
const Tooltip = TooltipPrimitive.Root;
const TooltipTrigger = TooltipPrimitive.Trigger;

const TooltipContent = React.forwardRef<
  React.ElementRef<typeof TooltipPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof TooltipPrimitive.Content>
>(({ className, sideOffset = 4, ...props }, ref) => (
  <TooltipPrimitive.Portal>
    <TooltipPrimitive.Content
      ref={ref}
      sideOffset={sideOffset}
      className={cn(
        "z-50 overflow-hidden rounded-lg bg-popover px-3 py-1.5 text-xs text-popover-foreground border-0 shadow-[0_12px_40px_-8px_rgba(0,0,0,0.18),0_2px_10px_-2px_rgba(0,0,0,0.08)] ring-1 ring-black/[0.06] dark:shadow-[0_12px_40px_-8px_rgba(0,0,0,0.5)] dark:ring-white/[0.08] animate-in fade-in-0 zoom-in-95",
        className,
      )}
      {...props}
    />
  </TooltipPrimitive.Portal>
));
TooltipContent.displayName = TooltipPrimitive.Content.displayName;

export { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger };
