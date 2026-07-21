import { Monitor, Moon, Sun } from "lucide-react";
import { useEffect, useState } from "react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "../components/ui/dropdown-menu";
import { Button } from "../components/ui/button";
import { cn } from "../lib/utils";

type Choice = "light" | "dark" | "system";

function currentChoice(): Choice {
  const src = document.documentElement.getAttribute("data-theme-source");
  if (src === "system") return "system";
  return (document.documentElement.getAttribute("data-theme") as "light" | "dark") ?? "system";
}

function effectiveTheme(): "light" | "dark" {
  return document.documentElement.getAttribute("data-theme") === "dark" ? "dark" : "light";
}

const OPTIONS: { id: Choice; label: string; Icon: typeof Sun }[] = [
  { id: "light", label: "Light", Icon: Sun },
  { id: "dark", label: "Dark", Icon: Moon },
  { id: "system", label: "System", Icon: Monitor },
];

/**
 * Light / dark / system theme switch. The actual theme is applied by a pre-paint
 * script in the SPA layout (no flash); this dispatches `longpi:set-theme` to it
 * and reflects the current effective theme. Hidden entirely in embed mode, where
 * the host forces the theme (data-theme-source="forced").
 */
export function ThemeToggle() {
  const [choice, setChoice] = useState<Choice>("system");
  const [effective, setEffective] = useState<"light" | "dark">("light");
  const [forced, setForced] = useState(false);

  useEffect(() => {
    setForced(document.documentElement.getAttribute("data-theme-source") === "forced");
    setChoice(currentChoice());
    setEffective(effectiveTheme());
    // Keep the icon in sync when the OS theme flips while on "system".
    const mq = matchMedia("(prefers-color-scheme: dark)");
    const onChange = () => setEffective(effectiveTheme());
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  if (forced) return null;

  function pick(next: Choice) {
    window.dispatchEvent(new CustomEvent("longpi:set-theme", { detail: next }));
    setChoice(next);
    // The pre-paint script has already updated data-theme synchronously.
    setEffective(effectiveTheme());
  }

  const Icon = effective === "dark" ? Moon : Sun;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="ghost" size="icon" className="size-7" aria-label="Theme">
          <Icon className="size-4" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-36">
        {OPTIONS.map(({ id, label, Icon: OptIcon }) => (
          <DropdownMenuItem key={id} onSelect={() => pick(id)} className="gap-2">
            <OptIcon className="size-4 text-muted-foreground" />
            <span className="flex-1">{label}</span>
            {choice === id && <span className="size-1.5 rounded-full bg-primary" />}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
