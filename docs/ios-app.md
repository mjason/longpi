# Longpi iOS 壳应用指南(WKWebView 嵌入)

Longpi 的 Web 已做好移动端适配(v0.1.63+):抽屉侧边栏、`h-dvh` 动态视口、
刘海/底部指示条 safe-area、触摸设备操作栏常显。iOS 端只需要一个薄薄的
WKWebView 壳。本文给出完整可抄的 Swift 代码与注意事项。

## 0. 服务端准备

- 服务器地址:局域网 `http://192.168.2.129:4080`(HTTP!需要 ATS 例外,见 §2)。
  公网部署时换成 HTTPS 域名,ATS 例外即可移除。
- 登录:若管理后台开启了"需要登录",WKWebView 里直接走网页登录即可,
  cookie 会持久化(见 §4)。另一条路是 embed 模式(`/embed?cwd=...&token=...`,
  管理后台 → Embed 页有 token 与参数说明),适合单工作区场景;完整 app 用
  主界面即可。

## 1. 工程设置(Xcode)

1. File → New → Project → iOS App(Interface: SwiftUI,Language: Swift)。
2. Deployment Target 建议 iOS 16+。
3. 只支持竖屏可在 Target → General → Deployment Info 里去掉横屏(可选)。

## 2. Info.plist:局域网 HTTP 的 ATS 例外

服务器是局域网 HTTP,必须放行(否则白屏)。Target → Info 加:

```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key>
  <true/>
  <!-- 若通过非 .local 的局域网 IP 访问,补一个域名例外: -->
  <key>NSExceptionDomains</key>
  <dict>
    <key>192.168.2.129</key>
    <dict>
      <key>NSExceptionAllowsInsecureHTTPLoads</key>
      <true/>
    </dict>
  </dict>
</dict>
<!-- 语音输入(composer 的麦克风按钮)需要: -->
<key>NSMicrophoneUsageDescription</key>
<string>语音输入需要使用麦克风</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>语音输入需要语音识别</string>
<!-- 附件里拍照/选图(<input type=file>)需要: -->
<key>NSCameraUsageDescription</key>
<string>发送照片附件需要使用相机</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>发送图片附件需要访问相册</string>
```

## 3. 完整的 WebView 壳(SwiftUI + WKWebView)

三个要点:cookie 持久化(登录态)、外链跳 Safari、下拉刷新。直接整体替换
`ContentView.swift`:

```swift
import SwiftUI
import WebKit

let LONGPI_URL = URL(string: "http://192.168.2.129:4080/")!

struct ContentView: View {
    var body: some View {
        WebView(url: LONGPI_URL)
            .ignoresSafeArea()          // 网页自己处理 safe-area(env() 变量)
            .background(Color(UIColor.systemBackground))
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 登录 cookie / localStorage 持久化(默认 default() 即磁盘存储)。
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        // 网页里的 window.open / target=_blank 交给壳处理(跳 Safari)。
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true   // 边缘右滑=返回
        webView.scrollView.contentInsetAdjustmentBehavior = .never  // 交给网页 env()
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground

        // 下拉刷新
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.reload(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @objc func reload(_ sender: UIRefreshControl) {
            (sender.superview?.superview as? WKWebView)?.reload()
            sender.endRefreshing()
        }

        // 站内导航留在 WebView;外部链接(消息里的 http 链接等)跳 Safari。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else {
                return decisionHandler(.allow)
            }
            let sameHost = target.host == LONGPI_URL.host
            if navigationAction.navigationType == .linkActivated && !sameHost {
                UIApplication.shared.open(target)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        // target=_blank(window.open)同样跳 Safari。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = navigationAction.request.url,
               target.host != LONGPI_URL.host {
                UIApplication.shared.open(target)
            } else if let target = navigationAction.request.url {
                webView.load(URLRequest(url: target))
            }
            return nil
        }

        // 网页里的 confirm()(删除会话等用到)映射成原生弹窗。
        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            topViewController()?.present(alert, animated: true)
        }

        // alert() 同理。
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
            topViewController()?.present(alert, animated: true)
        }

        private func topViewController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            var top = scenes.first?.keyWindow?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }
    }
}
```

## 4. 各功能在壳里的行为(都已验证的 Web 侧适配)

| 功能 | 行为 |
|---|---|
| 登录态 | `websiteDataStore = .default()` 磁盘持久化;登录一次长期有效 |
| 侧边栏 | 手机宽度自动变抽屉,左上角汉堡打开;选会话自动关闭 |
| 刘海/底部条 | 网页用 `env(safe-area-inset-*)` 自行留白(顶栏、composer);壳侧 `.ignoresSafeArea()` + `contentInsetAdjustmentBehavior = .never` 即可 |
| 键盘 | `h-dvh` 动态视口,键盘弹起时布局收缩,composer 不会被盖 |
| 附件/拍照 | `<input type=file>` WKWebView 原生支持(需 §2 的相机/相册权限描述) |
| 语音输入 | composer 麦克风用 Web Speech API,需 §2 的麦克风/语音识别权限 |
| 外部链接 | 壳的 delegate 跳 Safari,站内路由留在 WebView |
| 实时流 | Phoenix WebSocket 直接工作;app 退后台 iOS 会断 socket,回前台网页自动重连 |
| 深浅色 | 网页跟随系统(`data-theme`),无需壳侧处理 |

## 5. 可选进阶

- **单工作区模式**:`LONGPI_URL` 指向
  `http://<host>/embed?cwd=/path/to/ws&token=<embedToken>`(token 在
  管理后台 → Embed),得到无侧边栏的单项目视图。
- **HTTPS/公网**:上 Caddy/Tailscale 后把 URL 换成 https,删除 ATS 例外。
  Tailscale 方案:iPhone 装 Tailscale,URL 用 `http://<tailscale-ip>:4080`,
  ATS 用 `NSAllowsLocalNetworking` 即可覆盖。
- **App 图标**:`priv/static/images/favicon.svg` 的 π 设计可以直接放大重绘成
  1024×1024 App Icon(深底 #18181b、白 π、绿横杠 #34d399)。

## 6. 常见坑

1. **白屏** → 九成是 ATS:确认 §2 的 plist 例外,且 URL 的 IP/域名与例外一致。
2. **登录后刷新又退出** → 用了 `.nonPersistent()` 数据存储;必须 `.default()`。
3. **底部输入框贴到 Home 条** → 壳侧不要再加 safe-area padding(网页已处理),
   保持 `.ignoresSafeArea()`;重复留白反而出现双倍空隙。
4. **服务器升级后页面行为怪** → 下拉刷新即可(资源带指纹,刷新即取新版;
   RPC 403 会自动自愈重试)。
