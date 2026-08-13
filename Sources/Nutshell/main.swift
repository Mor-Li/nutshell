import AppKit

// 常驻后台的菜单栏小程序：不进 Dock、没有主窗口，只在菜单栏留一个图标。
//
// 包一层 assumeIsolated 是因为顶层代码不算在主线程上下文里，
// 而 AppDelegate 全程都要碰 UI。app.run() 不会返回，所以 delegate 一直活着。
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
