import { KeyRound, Loader2, Plus, Trash2, UserRound } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../../components/ui/button";
import { Input } from "../../components/ui/input";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "../../components/ui/popover";
import { Switch } from "../../components/ui/switch";
import { useI18n } from "../i18n";
import {
  type AuthStatus,
  deleteUser,
  loadAuthStatus,
  loadUsers,
  putUser,
  setAuthEnabled,
  type UserRow,
} from "../settings";

/**
 * Management → Users & sign-in. Everything account-related happens HERE:
 * the sign-in toggle (guarded — refuses to lock everyone out when no account
 * exists), adding accounts, resetting passwords, deleting. Passwords go
 * straight to the server and are stored hashed.
 */
export function UsersSection() {
  const { t } = useI18n();
  const [status, setStatus] = useState<AuthStatus | null>(null);
  const [users, setUsers] = useState<UserRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");

  async function refresh() {
    const [s, u] = await Promise.all([loadAuthStatus(), loadUsers()]);
    if (s) setStatus(s);
    setUsers(u);
  }

  useEffect(() => {
    refresh();
  }, []);

  if (!status) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  const canEnable = users.length > 0;

  async function toggle(next: boolean) {
    setError(null);
    // Guard in the UI too: enabling with zero accounts locks everyone out.
    if (next && !canEnable) {
      setError(t("usersPage.needUser"));
      return;
    }
    const err = await setAuthEnabled(next);
    if (err) setError(err);
    await refresh();
  }

  async function add() {
    setError(null);
    const err = await putUser(email.trim(), password);
    if (err) {
      setError(err);
      return;
    }
    setEmail("");
    setPassword("");
    await refresh();
  }

  async function remove(user: UserRow) {
    if (!confirm(t("usersPage.confirmDelete", { email: user.email }))) return;
    setError(null);
    const err = await deleteUser(user.id);
    if (err) setError(err);
    await refresh();
  }

  return (
    <div className="space-y-8 py-4">
      <section className="space-y-3">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-sm font-semibold">{t("usersPage.signin")}</h2>
            <p className="mt-0.5 text-xs text-muted-foreground">{t("usersPage.signinHint")}</p>
            {status.forced && (
              <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                {t("usersPage.signinForced")}
              </p>
            )}
            {!status.forced && !canEnable && !status.enabled && (
              <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                {t("usersPage.needUser")}
              </p>
            )}
          </div>
          <Switch
            checked={status.enabled}
            disabled={status.forced || (!status.enabled && !canEnable)}
            onCheckedChange={(next: boolean) => toggle(next)}
            aria-label={t("usersPage.signin")}
          />
        </div>
      </section>

      <section className="space-y-3">
        <div>
          <h2 className="text-sm font-semibold">{t("usersPage.accounts")}</h2>
          <p className="text-xs text-muted-foreground">{t("usersPage.accountsHint")}</p>
        </div>

        {users.length === 0 ? (
          <p className="text-sm text-muted-foreground">{t("usersPage.noUsers")}</p>
        ) : (
          <div className="divide-y divide-border rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
            {users.map((user) => (
              <div key={user.id} className="flex items-center gap-2.5 px-3 py-2 text-sm">
                <UserRound className="size-4 text-muted-foreground" />
                <span className="min-w-0 flex-1 truncate font-mono">{user.email}</span>
                <ResetPassword email={user.email} onDone={refresh} />
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={() => remove(user)}
                  aria-label={t("usersPage.deleteUser")}
                  className="size-7 text-muted-foreground hover:text-destructive"
                >
                  <Trash2 className="size-4" />
                </Button>
              </div>
            ))}
          </div>
        )}

        <div className="flex items-end gap-2">
          <Input
            className="w-64 font-mono text-xs"
            placeholder={t("usersPage.email")}
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <Input
            className="flex-1 font-mono text-xs"
            type="password"
            placeholder={t("usersPage.password")}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <Button disabled={!email.trim() || password.length < 8} onClick={() => void add()}>
            <Plus className="size-4" /> {t("usersPage.addUser")}
          </Button>
        </div>
        {error && <p className="text-xs text-destructive">{error}</p>}
      </section>
    </div>
  );
}

function ResetPassword({ email, onDone }: { email: string; onDone: () => void }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);

  async function save() {
    const err = await putUser(email, password);
    if (err) {
      setError(err);
      return;
    }
    setPassword("");
    setError(null);
    setOpen(false);
    onDone();
  }

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="sm"
          className="h-7 gap-1 px-2 text-xs text-muted-foreground hover:text-foreground"
        >
          <KeyRound className="size-3.5" /> {t("usersPage.resetPassword")}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-72 space-y-2 p-3">
        <p className="truncate font-mono text-xs text-muted-foreground">{email}</p>
        <Input
          type="password"
          className="text-xs"
          placeholder={t("usersPage.newPassword")}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
        {error && <p className="text-xs text-destructive">{error}</p>}
        <Button size="sm" className="w-full" disabled={password.length < 8} onClick={() => void save()}>
          {t("common.save")}
        </Button>
      </PopoverContent>
    </Popover>
  );
}
