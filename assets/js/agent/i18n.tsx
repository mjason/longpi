import { createContext, useCallback, useContext, useMemo, useState } from "react";

/**
 * Lightweight i18n (dala's model): flat key dictionaries, a `t()` hook, and a
 * persisted language choice. Default follows the browser (`zh*` → 中文), and
 * `localStorage["longpi:lang"]` overrides. `t(key, params)` interpolates
 * `{name}` placeholders.
 */

export type Lang = "zh" | "en";

const en = {
  // Sidebar / chat chrome
  "sidebar.newConversation": "New conversation",
  "sidebar.extensions": "Extensions",
  "sidebar.projects": "Projects",
  "sidebar.noConversations": "No conversations yet.",
  "sidebar.newConversationHere": "New conversation here",
  "sidebar.deleteConversation": "Delete conversation",
  "sidebar.deleteProject": "Delete project",
  "sidebar.settings": "Settings",
  "sidebar.signOut": "Sign out",
  "confirm.deleteConversation": 'Delete "{name}"? This cannot be undone.',
  "confirm.deleteProject":
    'Delete project "{name}" and its {count} conversation(s)? This cannot be undone.',
  "welcome.pickWorkspace":
    "Pick a workspace on the left, or start a new conversation to put the agent to work.",
  "welcome.howCanIHelp": "How can I help you today?",
  "pane.contextCompacted": "context compacted",

  // Theme
  "theme.light": "Light",
  "theme.dark": "Dark",
  "theme.system": "System",
  "theme.label": "Theme",

  // Language
  "lang.label": "Language",

  // Composer
  "composer.placeholder": "Send a message…  (/compact to compress context)",
  "composer.send": "Send message",
  "composer.stop": "Stop",
  "composer.attach": "Add Attachment",
  "composer.voice": "Voice input",
  "composer.reasoning": "Reasoning effort",
  "reasoning.auto": "Auto",
  "reasoning.autoHint": "Let the model decide (no override).",
  "reasoning.minimal": "Minimal",
  "reasoning.minimalHint": "Barely any reasoning — fastest.",
  "reasoning.low": "Low",
  "reasoning.lowHint": "A little reasoning.",
  "reasoning.medium": "Medium",
  "reasoning.mediumHint": "Balanced reasoning.",
  "reasoning.high": "High",
  "reasoning.highHint": "Think hard — slowest, most thorough.",

  // Message actions
  "msg.copy": "Copy",
  "msg.regenerate": "Regenerate",
  "msg.more": "More",

  // New conversation dialog
  "newConv.title": "New conversation",
  "newConv.workspace": "Workspace",
  "newConv.model": "Model",
  "newConv.create": "Create",

  // Update check
  "update.updateTo": "Update to v{version}",
  "update.updating": "Updating…",
  "update.restarting": "Restarting…",
  "update.serverVersion": "Server version",

  // Embed view
  "embed.missingCwd": "Missing ?cwd= — the host must say which workspace to open.",
  "embed.loadFailed": "Could not load conversations.",
  "embed.createFailed": "Could not create a conversation for this workspace.",
  "embed.threads": "Conversations in this workspace",

  // Management shell
  "manage.title": "Management",
  "manage.close": "Close",
  "manage.group.agent": "Agent",
  "manage.group.extend": "Extend",
  "manage.group.data": "Data",
  "manage.general": "General",
  "manage.general.desc": "Approval, default model, system prompt, and context compaction.",
  "manage.providers": "Providers",
  "manage.providers.desc": "LLM provider credentials and OpenAI-compatible gateways.",
  "manage.models": "Models",
  "manage.models.desc": "The models available to new conversations.",
  "manage.tools": "Prompts & Tools",
  "manage.tools.desc": "The description each built-in tool advertises to the model.",
  "manage.extensions": "Extensions",
  "manage.extensions.desc": "Global extensions and installed packages.",
  "manage.embed": "Embed",
  "manage.embed.desc": "Embed the agent in another app (iframe + token).",
  "manage.conversations": "Conversations",
  "manage.conversations.desc": "Every conversation, with usage and cleanup.",
  "manage.sessions": "Sessions",
  "manage.sessions.desc": "Live agent processes running right now.",

  "manage.users": "Users & sign-in",
  "manage.users.desc": "Accounts and the sign-in requirement.",

  // Users management section
  "usersPage.signin": "Require sign-in",
  "usersPage.signinHint":
    "When on, every page, API call, and websocket needs a signed-in user (or the embed token). Takes effect immediately.",
  "usersPage.signinForced": "Pinned by config.jsonc / LONGPI_AUTH_ENABLED — the toggle is read-only.",
  "usersPage.needUser": "Add a user first — enabling sign-in with no accounts would lock everyone out.",
  "usersPage.accounts": "Accounts",
  "usersPage.accountsHint": "Passwords are stored hashed; saving an existing email resets its password.",
  "usersPage.email": "Email",
  "usersPage.password": "Password (min 8 chars)",
  "usersPage.addUser": "Add user",
  "usersPage.resetPassword": "Reset password",
  "usersPage.newPassword": "New password",
  "usersPage.deleteUser": "Delete account",
  "usersPage.confirmDelete": "Delete {email}? They will no longer be able to sign in.",
  "usersPage.lastAccount": "cannot delete the last account while sign-in is on",
  "usersPage.noUsers": "No accounts yet.",

  // Embed management section
  "embedPage.status": "Status",
  "embedPage.authOn": "Sign-in required — iframes must carry the token below.",
  "embedPage.authOff":
    "Sign-in is disabled, so embedding works without a token. Enable auth in config.jsonc for protection.",
  "embedPage.token": "Embed token",
  "embedPage.tokenHint":
    "Auto-generated into <dataDir>/secrets.json (\"embedToken\"). Treat it like a password; the host app appends it to the iframe URL.",
  "embedPage.snippet": "Iframe snippet",
  "embedPage.snippetHint":
    "Replace the cwd with the workspace the embedded agent should open. theme is optional (dark | light); model overrides the default model.",
  "embedPage.copy": "Copy",
  "embedPage.copied": "Copied",
  "embedPage.params": "Parameters",
  "embedPage.param.cwd": "workspace to open (required)",
  "embedPage.param.theme": "force dark or light (host-controlled)",
  "embedPage.param.model": "model for a newly created conversation (optional)",
  "embedPage.param.token": "the embed token above (required when sign-in is on)",

  // Slash commands (the "/" menu; extension commands keep their own text)
  "slash.compact": "Summarize older messages to free up context",
  "slash.model": "Switch the model, e.g. /model openai:gpt-5.4",
  "slash.reload": "Reload extensions (pick up newly written ones)",
  "slash.rename": "Rename this conversation, e.g. /rename 部署调优",
  "slash.help": "List the available commands",

  // Common
  "common.save": "Save",
  "common.saved": "Saved",
  "common.add": "Add",
  "common.refresh": "Refresh",
} as const;

export type I18nKey = keyof typeof en;

const zh: Record<I18nKey, string> = {
  "sidebar.newConversation": "新建会话",
  "sidebar.extensions": "扩展",
  "sidebar.projects": "项目",
  "sidebar.noConversations": "还没有会话。",
  "sidebar.newConversationHere": "在此项目新建会话",
  "sidebar.deleteConversation": "删除会话",
  "sidebar.deleteProject": "删除项目",
  "sidebar.settings": "设置",
  "sidebar.signOut": "退出登录",
  "confirm.deleteConversation": "删除「{name}」？此操作不可撤销。",
  "confirm.deleteProject": "删除项目「{name}」及其 {count} 个会话？此操作不可撤销。",
  "welcome.pickWorkspace": "从左侧选择一个工作区，或新建会话让 agent 开始干活。",
  "welcome.howCanIHelp": "今天要做点什么？",
  "pane.contextCompacted": "上下文已压缩",

  "theme.light": "浅色",
  "theme.dark": "深色",
  "theme.system": "跟随系统",
  "theme.label": "主题",

  "lang.label": "语言",

  "composer.placeholder": "发送消息…  （/compact 可压缩上下文）",
  "composer.send": "发送",
  "composer.stop": "停止",
  "composer.attach": "添加附件",
  "composer.voice": "语音输入",
  "composer.reasoning": "推理强度",
  "reasoning.auto": "自动",
  "reasoning.autoHint": "由模型自行决定（不覆盖）。",
  "reasoning.minimal": "最少",
  "reasoning.minimalHint": "几乎不推理——最快。",
  "reasoning.low": "低",
  "reasoning.lowHint": "少量推理。",
  "reasoning.medium": "中",
  "reasoning.mediumHint": "均衡推理。",
  "reasoning.high": "高",
  "reasoning.highHint": "深入思考——最慢、最全面。",

  "msg.copy": "复制",
  "msg.regenerate": "重新生成",
  "msg.more": "更多",

  "newConv.title": "新建会话",
  "newConv.workspace": "工作区",
  "newConv.model": "模型",
  "newConv.create": "创建",

  "update.updateTo": "更新到 v{version}",
  "update.updating": "更新中…",
  "update.restarting": "重启中…",
  "update.serverVersion": "服务端版本",

  "embed.missingCwd": "缺少 ?cwd= 参数——宿主需要指定打开哪个工作区。",
  "embed.loadFailed": "无法加载会话。",
  "embed.createFailed": "无法为该工作区创建会话。",
  "embed.threads": "该工作区的会话",

  "manage.title": "管理",
  "manage.close": "关闭",
  "manage.group.agent": "Agent",
  "manage.group.extend": "扩展",
  "manage.group.data": "数据",
  "manage.general": "通用",
  "manage.general.desc": "审批级别、默认模型、系统提示与上下文压缩。",
  "manage.providers": "供应商",
  "manage.providers.desc": "LLM 供应商凭据与 OpenAI 兼容网关。",
  "manage.models": "模型",
  "manage.models.desc": "新会话可用的模型列表。",
  "manage.tools": "提示词与工具",
  "manage.tools.desc": "每个内置工具向模型声明的描述。",
  "manage.extensions": "扩展",
  "manage.extensions.desc": "全局扩展与已安装的包。",
  "manage.embed": "嵌入",
  "manage.embed.desc": "把 agent 嵌入其它应用（iframe + token）。",
  "manage.conversations": "会话",
  "manage.conversations.desc": "全部会话，可查看与清理。",
  "manage.sessions": "运行中",
  "manage.sessions.desc": "当前正在运行的 agent 进程。",

  "manage.users": "用户与登录",
  "manage.users.desc": "账号管理与登录开关。",

  "usersPage.signin": "需要登录",
  "usersPage.signinHint":
    "开启后，所有页面、API 与 websocket 都需要登录（或嵌入 token）。立即生效。",
  "usersPage.signinForced": "已被 config.jsonc / LONGPI_AUTH_ENABLED 固定——此开关只读。",
  "usersPage.needUser": "请先添加用户——没有账号就开启登录会把所有人锁在外面。",
  "usersPage.accounts": "账号",
  "usersPage.accountsHint": "密码以哈希存储；对已有邮箱保存即重置其密码。",
  "usersPage.email": "邮箱",
  "usersPage.password": "密码（至少 8 位）",
  "usersPage.addUser": "添加用户",
  "usersPage.resetPassword": "重置密码",
  "usersPage.newPassword": "新密码",
  "usersPage.deleteUser": "删除账号",
  "usersPage.confirmDelete": "删除 {email}？该账号将无法再登录。",
  "usersPage.lastAccount": "开启登录时不能删除最后一个账号",
  "usersPage.noUsers": "还没有账号。",

  "embedPage.status": "状态",
  "embedPage.authOn": "已开启登录——iframe 必须携带下方 token。",
  "embedPage.authOff": "未开启登录，嵌入无需 token。如需保护请在 config.jsonc 开启 auth。",
  "embedPage.token": "嵌入 Token",
  "embedPage.tokenHint":
    "自动生成于 <dataDir>/secrets.json（\"embedToken\"）。请像密码一样保管；宿主应用把它拼进 iframe 地址。",
  "embedPage.snippet": "Iframe 代码",
  "embedPage.snippetHint":
    "把 cwd 换成要打开的工作区。theme 可选（dark | light）；model 可覆盖默认模型。",
  "embedPage.copy": "复制",
  "embedPage.copied": "已复制",
  "embedPage.params": "参数说明",
  "embedPage.param.cwd": "要打开的工作区（必填）",
  "embedPage.param.theme": "强制深色或浅色（由宿主控制）",
  "embedPage.param.model": "新建会话时使用的模型（可选）",
  "embedPage.param.token": "上方的嵌入 token（开启登录时必填）",

  "slash.compact": "压缩较早的消息以释放上下文",
  "slash.model": "切换模型，如 /model openai:gpt-5.4",
  "slash.reload": "重新加载扩展（加载新写入的扩展）",
  "slash.rename": "重命名当前会话，如 /rename 部署调优",
  "slash.help": "列出可用命令",

  "common.save": "保存",
  "common.saved": "已保存",
  "common.add": "添加",
  "common.refresh": "刷新",
};

const DICTS: Record<Lang, Record<I18nKey, string>> = { en, zh };

function detectLang(): Lang {
  try {
    const saved = localStorage.getItem("longpi:lang");
    if (saved === "zh" || saved === "en") return saved;
  } catch {
    // sandboxed iframe — fall through to the navigator
  }
  return navigator.language?.toLowerCase().startsWith("zh") ? "zh" : "en";
}

type I18n = {
  lang: Lang;
  setLang: (lang: Lang) => void;
  t: (key: I18nKey, params?: Record<string, string | number>) => string;
};

const I18nContext = createContext<I18n | null>(null);

export function I18nProvider({ children }: { children: React.ReactNode }) {
  const [lang, setLangState] = useState<Lang>(detectLang);

  const setLang = useCallback((next: Lang) => {
    setLangState(next);
    try {
      localStorage.setItem("longpi:lang", next);
    } catch {
      // sandboxed iframe — the choice just won't persist
    }
  }, []);

  const t = useCallback(
    (key: I18nKey, params?: Record<string, string | number>) => {
      let text: string = DICTS[lang][key] ?? en[key] ?? key;
      if (params) {
        for (const [name, value] of Object.entries(params)) {
          text = text.replaceAll(`{${name}}`, String(value));
        }
      }
      return text;
    },
    [lang],
  );

  const value = useMemo(() => ({ lang, setLang, t }), [lang, setLang, t]);
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n(): I18n {
  const ctx = useContext(I18nContext);
  if (!ctx) throw new Error("useI18n must be used within I18nProvider");
  return ctx;
}

/** Dictionaries exported for the completeness unit test. */
export const DICTIONARIES = DICTS;
