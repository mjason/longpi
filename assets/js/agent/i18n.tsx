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
  "msg.edit": "Edit",
  "msg.cancel": "Cancel",
  "msg.update": "Update",
  "msg.fork": "New conversation from here",

  // Subagents
  "subagents.title": "Agents",
  "subagents.status.running": "Running",
  "subagents.status.done": "Done",
  "subagents.status.failed": "Failed",
  "subagents.status.closed": "Closed",
  "subagents.clickToOpen": "Click to open its conversation",
  "subagents.childBadge": "Subagent · {role}",
  "subagents.backToParent": "Back to parent conversation",
  "subagentApproval.wants": "wants to run",
  "subagentApproval.allow": "Allow",
  "subagentApproval.deny": "Deny",

  // File / link preview dialogs
  "file.notFound": "File not found.",
  "file.binary": "This file can't be previewed — download it to view.",
  "file.truncated": "Preview truncated — showing the first 256 KB.",
  "file.copyPath": "Copy path",
  "file.download": "Download",
  "link.openExternal": "Open external link?",
  "link.externalWarning": "You're about to visit an external website.",
  "link.copy": "Copy link",
  "link.open": "Open link",

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
  "slash.loop": "Loop a task until done, e.g. /loop 10 fix all tests — /loop stop ends it",
  "slash.help": "List the available commands",

  // Management: settings tabs (General / Providers / Prompts & Tools)
  "settings.approvalLevel": "Approval level",
  "settings.approvalLevelHint": "How much the agent may do without asking you first.",
  "tiers.title": "Model tiers",
  "tiers.hint":
    "Named tiers that subagent roles and tools reference instead of model specs — each bundles a model and a reasoning level; remap here when providers change. J = light & fast, Q = balanced, K = strongest.",
  "tiers.unmapped": "Not mapped",
  "tiers.custom.placeholder": "Custom tier name",
  "tiers.add": "Add tier",
  "tiers.J": "Light & fast — scouting, summarizing, bulk chores",
  "tiers.Q": "Balanced — everyday implementation work",
  "tiers.K": "Strongest — deep reasoning and hard problems",
  "settings.approval.read_only": "Read-only",
  "settings.approval.read_only.hint": "Only reads run automatically; writes and commands ask.",
  "settings.approval.auto": "Auto",
  "settings.approval.auto.hint": "Reads and file edits run; bash commands ask.",
  "settings.approval.full": "Full access",
  "settings.approval.full.hint": "Everything runs automatically — no prompts.",
  "settings.defaultModel": "Default model",
  "settings.defaultModelHint": "Prefills new conversations.",
  "settings.systemPrompt": "System prompt",
  "settings.systemPromptHint":
    "Sent at the start of every conversation. Edit freely; use {{cwd}} for the workspace path.",
  "settings.usingDefault": "Using the built-in default.",
  "settings.customized": "Customized.",
  "settings.resetToDefault": "reset to default",
  "settings.compaction": "Context compaction",
  "settings.compactionHint":
    "When a conversation nears the model's context window, older messages are summarized to make room. The full history stays stored.",
  "settings.enabled": "Enabled",
  "settings.compactAt": "compact at {pct}% of window",
  "settings.providersIntro":
    "API credentials per provider. Keys are write-only — once saved they never leave the server. For an OpenAI-compatible gateway, set the base URL and discover its models with one click.",
  "settings.noProviders": "No providers yet. Falls back to environment variables until you add one.",
  "settings.addProvider": "Add provider",
  "settings.keySet": "key set",
  "settings.noKey": "no key",
  "settings.removeProvider": "Remove provider",
  "settings.displayNamePlaceholder": "display name (e.g. listenai)",
  "settings.baseUrlPlaceholder": "base URL (e.g. https://openrouter.listenai.com/v1)",
  "settings.keyKeepPlaceholder": "•••••••• (leave blank to keep)",
  "settings.keyPlaceholder": "api key",
  "settings.discoverModels": "Discover models",
  "settings.modelsFound": "{count} models found. Select the ones to add.",
  "settings.addToModels": "Add {count} to Models",
  "settings.removeProviderConfirm":
    'Remove provider "{name}"? Saved models keep working only if another provider serves them.',
  "settings.toolsIntro":
    "The description each tool advertises to the model. Reset restores the built-in text.",
  "settings.reset": "reset",
  "settings.saveToolDescriptions": "Save tool descriptions",

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
  "msg.edit": "编辑",
  "msg.cancel": "取消",
  "msg.update": "更新",
  "msg.fork": "从这里开新会话",

  // Subagents
  "subagents.title": "子 Agent",
  "subagents.status.running": "运行中",
  "subagents.status.done": "已完成",
  "subagents.status.failed": "失败",
  "subagents.status.closed": "已关闭",
  "subagents.clickToOpen": "点击查看它的会话",
  "subagents.childBadge": "子 Agent · {role}",
  "subagents.backToParent": "返回父会话",
  "subagentApproval.wants": "请求运行",
  "subagentApproval.allow": "允许",
  "subagentApproval.deny": "拒绝",

  // File / link preview dialogs
  "file.notFound": "文件不存在。",
  "file.binary": "此文件无法预览——可下载查看。",
  "file.truncated": "预览已截断——仅显示前 256 KB。",
  "file.copyPath": "复制路径",
  "file.download": "下载",
  "link.openExternal": "打开外部链接?",
  "link.externalWarning": "即将访问外部网站。",
  "link.copy": "复制链接",
  "link.open": "打开链接",

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
  "slash.loop": "循环执行任务直到完成，如 /loop 10 修完所有测试 —— /loop stop 结束",
  "slash.help": "列出可用命令",

  // 管理：设置页（通用 / 提供方 / 提示词与工具）
  "settings.approvalLevel": "授权级别",
  "settings.approvalLevelHint": "在不询问你的情况下，agent 可以自行做多少事。",
  "tiers.title": "模型档位",
  "tiers.hint":
    "子代理角色和工具引用档位而不是写死模型名，每个档位打包一个模型和一个推理等级，换 provider 时只需在这里重新映射。J = 轻快、Q = 均衡、K = 最强。",
  "tiers.unmapped": "未映射",
  "tiers.custom.placeholder": "自定义档位名",
  "tiers.add": "添加档位",
  "tiers.J": "轻快 — 侦察、总结、批量琐事",
  "tiers.Q": "均衡 — 日常实现工作",
  "tiers.K": "最强 — 深度推理与难题",
  "settings.approval.read_only": "只读",
  "settings.approval.read_only.hint": "只有读取自动执行；写入和命令都会询问。",
  "settings.approval.auto": "自动",
  "settings.approval.auto.hint": "读取和文件编辑自动执行；bash 命令会询问。",
  "settings.approval.full": "完全访问",
  "settings.approval.full.hint": "一切自动执行——不再询问。",
  "settings.defaultModel": "默认模型",
  "settings.defaultModelHint": "新会话的预填模型。",
  "settings.systemPrompt": "系统提示词",
  "settings.systemPromptHint": "在每个会话开始时发送。可自由编辑；用 {{cwd}} 表示工作区路径。",
  "settings.usingDefault": "正在使用内置默认值。",
  "settings.customized": "已自定义。",
  "settings.resetToDefault": "恢复默认",
  "settings.compaction": "上下文压缩",
  "settings.compactionHint":
    "当会话接近模型的上下文窗口时，较早的消息会被总结以腾出空间。完整历史仍会保存。",
  "settings.enabled": "启用",
  "settings.compactAt": "在窗口的 {pct}% 处压缩",
  "settings.providersIntro":
    "每个提供方的 API 凭据。密钥只写——保存后绝不离开服务器。对于 OpenAI 兼容网关，设置 base URL 即可一键发现其模型。",
  "settings.noProviders": "还没有提供方。在你添加之前会回退到环境变量。",
  "settings.addProvider": "添加提供方",
  "settings.keySet": "已设密钥",
  "settings.noKey": "无密钥",
  "settings.removeProvider": "移除提供方",
  "settings.displayNamePlaceholder": "显示名称（如 listenai）",
  "settings.baseUrlPlaceholder": "base URL（如 https://openrouter.listenai.com/v1）",
  "settings.keyKeepPlaceholder": "••••••••（留空则保持不变）",
  "settings.keyPlaceholder": "api key",
  "settings.discoverModels": "发现模型",
  "settings.modelsFound": "发现 {count} 个模型。勾选要添加的。",
  "settings.addToModels": "添加 {count} 个到模型",
  "settings.removeProviderConfirm":
    "移除提供方「{name}」？只有当其他提供方也提供这些模型时，已保存的模型才会继续可用。",
  "settings.toolsIntro": "每个工具向模型宣告的描述。重置可恢复内置文本。",
  "settings.reset": "重置",
  "settings.saveToolDescriptions": "保存工具描述",

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
