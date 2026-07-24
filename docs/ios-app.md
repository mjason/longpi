# Longpi iOS 应用指南 —— 原生导航 + WebView 聊天页

架构(Hotwire Native 思路的精简版,导航体验 100% 原生):

```
SwiftUI NavigationStack(原生导航栏/转场/手势)
 ├── 会话列表页   ← 原生 List(大标题、下拉刷新、swipe 删除)
 │      数据: GET /api/mobile/conversations?token=...
 ├── 聊天页       ← WKWebView 加载 /m/c/<id>?token=...(裸对话视图,无 web 顶栏)
 └── 新建会话     ← 原生 Sheet(目录 + 模型),POST /api/mobile/conversations
```

服务端已提供(v0.1.64+):

| 端点 | 说明 |
|---|---|
| `GET /api/mobile/conversations?token=` | 会话列表(新→旧,子代理会话已排除) |
| `POST /api/mobile/conversations?token=` | `{cwd, model?}` 创建(model 缺省用后台默认) |
| `DELETE /api/mobile/conversations/:id?token=` | 删除 |
| `GET /api/mobile/models?token=` | 启用的模型 + 默认模型 |
| `GET /m/c/:id?token=&theme=dark\|light` | 裸聊天页(WebView 用;token 同时授权 WebSocket) |
| `GET /api/mobile/status?token=` | 启动探测:{auth_enabled, authorized} |
| `POST /api/mobile/login` | `{email, password}` → `{token}`(原生登录换 token) |

`token` = 管理后台 → Embed 页的 embedToken。**未开启登录时可省略**。

---

## 1. 工程与 Info.plist

Xcode → iOS App(SwiftUI,iOS 16+)。Info.plist(局域网 HTTP 必配,否则白屏):

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
  <key>NSExceptionDomains</key>
  <dict>
    <key>192.168.2.129</key>
    <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
  </dict>
</dict>
<key>NSMicrophoneUsageDescription</key><string>语音输入需要使用麦克风</string>
<key>NSSpeechRecognitionUsageDescription</key><string>语音输入需要语音识别</string>
<key>NSCameraUsageDescription</key><string>发送照片附件需要使用相机</string>
<key>NSPhotoLibraryUsageDescription</key><string>发送图片附件需要访问相册</string>
```

## 2. 登录方案:标准登录界面,底层账号密码换 token

启动流程(服务端 v0.1.65+ 已就绪):

```
启动 → GET /api/mobile/status[?token=Keychain里的token]
  ├─ auth_enabled=false            → 直接进列表(无需任何凭证)
  ├─ authorized=true               → 直接进列表(token 仍有效)
  └─ 否则                          → 弹原生登录页(邮箱+密码)
        POST /api/mobile/login {email, password}
          ├─ 200 {token} → 存 Keychain → 进列表
          └─ 401         → 提示密码错误
```

- 用户看到的是**普通的账号密码登录**(账号即 web 端账号,后台 Users 页管理)
- 密码只在登录瞬间使用;换回的 token 存 Keychain 作为长期凭证,后续所有
  API/WebView/WebSocket 统一用它
- 为什么不直接用网页登录 cookie:WKWebView(WKHTTPCookieStore)与原生
  URLSession(HTTPCookieStorage)的 cookie **不互通**,同步是 hybrid 经典大坑;
  token 两边天然一致

```swift
// LoginView.swift — 原生登录页
import SwiftUI

struct LoginView: View {
    var onLoggedIn: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("邮箱", text: $email)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none).disableAutocorrection(true)
                SecureField("密码", text: $password)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                Button(busy ? "登录中…" : "登录") { Task { await login() } }
                    .disabled(busy || email.isEmpty || password.isEmpty)
            }
            .navigationTitle("登录 Longpi")
        }
    }

    func login() async {
        busy = true; defer { busy = false }
        struct R: Decodable { let token: String? }
        var req = URLRequest(url: Config.base.appendingPathComponent("/api/mobile/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONEncoder().encode(["email": email, "password": password])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let token = try JSONDecoder().decode(R.self, from: data).token else {
                error = "邮箱或密码不正确"; return
            }
            Keychain.set(token, for: "embedToken")
            onLoggedIn()
        } catch { self.error = "无法连接服务器" }
    }
}

// App 入口:启动探测 → 决定登录/直进
@main
struct LongpiApp: App {
    @State private var state: BootState = .checking
    enum BootState { case checking, needsLogin, ready }

    var body: some Scene {
        WindowGroup {
            switch state {
            case .checking:
                ProgressView().task { await probe() }
            case .needsLogin:
                LoginView { state = .ready }
            case .ready:
                ConversationListView()
            }
        }
    }

    func probe() async {
        struct R: Decodable { let auth_enabled: Bool; let authorized: Bool }
        let url = Config.api("/api/mobile/status")   // 自动带 Keychain 里的 token
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(R.self, from: data) else {
            state = .needsLogin   // 连不上也先给登录页(内含服务器提示)
            return
        }
        state = r.authorized ? .ready : .needsLogin
    }
}
```

```swift
// Keychain.swift — 最小可用的 Keychain 读写
import Security
import Foundation

enum Keychain {
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// SettingsView.swift — 首启/设置页:服务器 + token
import SwiftUI

struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = "http://192.168.2.129:4080"
    @State private var token = Keychain.get("embedToken") ?? ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("http://host:4080", text: $serverURL)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .keyboardType(.URL)
                }
                Section("凭证") {
                    SecureField("embedToken(管理后台 → Embed)", text: $token)
                    Text("未开启登录的服务器可留空")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("连接设置")
            .toolbar {
                Button("保存") {
                    Keychain.set(token, for: "embedToken")
                    dismiss()
                }
            }
        }
    }
}
```

列表页在 `.task { await reload() }` 收到 401 时弹出 `SettingsView` 即可
(`.sheet(isPresented: $needsSetup) { SettingsView() }`)。

服务端校验行为:`Longpi.Auth` 未开启登录时 API 全放行(token 可空);开启后
每个请求都验 token,WebView 的 `?token=` 同时授权 WebSocket。token 是全权限
凭证 —— 走公网务必配 HTTPS 或 Tailscale。

## 3. 配置与 API 客户端

```swift
// Config.swift
enum Config {
    static var base: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL")
            ?? "http://192.168.2.129:4080")!
    }
    static var token: String { Keychain.get("embedToken") ?? "" }

    static func api(_ path: String) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !token.isEmpty { comps.queryItems = [.init(name: "token", value: token)] }
        return comps.url!
    }

    static func chatURL(id: String, dark: Bool) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("/m/c/\(id)"),
                                  resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "theme", value: dark ? "dark" : "light")]
        if !token.isEmpty { items.append(.init(name: "token", value: token)) }
        comps.queryItems = items
        return comps.url!
    }
}

// Models.swift
struct Conversation: Identifiable, Decodable, Hashable {
    let id: String
    let title: String?
    let cwd: String
    let model: String

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return cwd.split(separator: "/").last.map(String.init) ?? cwd
    }
    var project: String { cwd.split(separator: "/").last.map(String.init) ?? cwd }
}

struct ModelChoice: Decodable, Hashable { let spec: String; let label: String? }

// Api.swift
enum Api {
    static func conversations() async throws -> [Conversation] {
        struct R: Decodable { let conversations: [Conversation] }
        let (data, _) = try await URLSession.shared.data(from: Config.api("/api/mobile/conversations"))
        return try JSONDecoder().decode(R.self, from: data).conversations
    }

    static func createConversation(cwd: String, model: String?) async throws -> Conversation {
        var req = URLRequest(url: Config.api("/api/mobile/conversations"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: String] = ["cwd": cwd]
        if let model { body["model"] = model }
        req.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Conversation.self, from: data)
    }

    static func deleteConversation(id: String) async throws {
        var req = URLRequest(url: Config.api("/api/mobile/conversations/\(id)"))
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    static func models() async throws -> (models: [ModelChoice], default: String) {
        struct R: Decodable { let models: [ModelChoice]; let `default`: String }
        let (data, _) = try await URLSession.shared.data(from: Config.api("/api/mobile/models"))
        let r = try JSONDecoder().decode(R.self, from: data)
        return (r.models, r.default)
    }
}
```

## 4. 会话列表(原生导航的主场)

```swift
// ConversationListView.swift
import SwiftUI

struct ConversationListView: View {
    @State private var conversations: [Conversation] = []
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations) { c in
                    NavigationLink(value: c) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayTitle).font(.body).lineLimit(1)
                            Text(c.project).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    let doomed = indexSet.map { conversations[$0] }
                    conversations.remove(atOffsets: indexSet)
                    Task { for c in doomed { try? await Api.deleteConversation(id: c.id) } }
                }
            }
            .navigationTitle("Longpi")
            .navigationDestination(for: Conversation.self) { c in
                ChatView(conversation: c)
            }
            .toolbar {
                Button { showNew = true } label: { Image(systemName: "square.and.pencil") }
            }
            .refreshable { await reload() }
            .task { await reload() }
            .sheet(isPresented: $showNew) {
                NewConversationSheet { created in
                    conversations.insert(created, at: 0)
                }
            }
        }
    }

    func reload() async {
        if let list = try? await Api.conversations() { conversations = list }
    }
}
```

## 5. 聊天页(WKWebView 装裸对话视图)

原生导航栏显示标题;网页只有对话流(web 顶栏在 `/m/c/:id` 下已移除)。

```swift
// ChatView.swift
import SwiftUI
import WebKit

struct ChatView: View {
    let conversation: Conversation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ChatWebView(url: Config.chatURL(id: conversation.id, dark: scheme == .dark))
            .ignoresSafeArea(edges: .bottom)   // 网页自己处理底部 safe-area
            .navigationTitle(conversation.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct ChatWebView: UIViewRepresentable {
    let url: URL

    // 每个聊天页一个 WebView;cookie/localStorage 全 app 共享(登录态、token 授权)。
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        // 消息里的外部链接跳 Safari;本站导航留在页内。
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated,
               let target = action.request.url, target.host != Config.base.host {
                UIApplication.shared.open(target)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
```

## 6. 新建会话 Sheet

```swift
// NewConversationSheet.swift
import SwiftUI

struct NewConversationSheet: View {
    var onCreated: (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cwd = ""
    @State private var models: [ModelChoice] = []
    @State private var model = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("/path/to/workspace", text: $cwd)
                    .autocapitalization(.none).disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                Picker("模型", selection: $model) {
                    ForEach(models, id: \.spec) { m in
                        Text(m.label ?? m.spec).tag(m.spec)
                    }
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task {
                            if let c = try? await Api.createConversation(
                                cwd: cwd, model: model.isEmpty ? nil : model) {
                                onCreated(c); dismiss()
                            }
                        }
                    }
                    .disabled(cwd.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                if let r = try? await Api.models() { models = r.models; model = r.default }
            }
        }
    }
}
```

## 7. 行为说明

- **导航**:列表→聊天是真 UINavigationController push(原生转场、边缘返回、
  导航栏标题),这正是 Hotwire Native 的体验模型。
- **实时流**:聊天页 WebSocket 在 WebView 内自动连接(`?token=` 已授权
  session);退后台断开、回前台自动重连。
- **主题**:`theme=dark|light` 由壳按系统外观传入,WebView 内容与原生 UI 一致。
- **列表刷新**:从聊天返回列表后标题可能已被 AI 自动命名 —— 下拉刷新即可;
  想自动化可在 `ChatView.onDisappear` 里触发一次 `reload()`。
- **附件/语音**:WKWebView 原生支持 `<input type=file>` 与 Web Speech
  (§1 的权限描述必须配)。

## 8. 常见坑

1. **白屏** → ATS(§1);URL host 必须与例外一致。
2. **WebSocket 连不上 / 一直转圈** → token 没带上或不对:开着登录时
   `/m/c/:id` 必须带 `?token=`,检查 `Config.token`。
3. **登录态丢失** → 必须 `websiteDataStore = .default()`(默认磁盘持久)。
4. **底部双倍留白** → 壳侧保持 `.ignoresSafeArea(edges: .bottom)` +
   `contentInsetAdjustmentBehavior = .never`,底部 safe-area 网页已处理。
