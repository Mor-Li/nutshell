import Carbon.HIToolbox

/// 浮窗露脸期间，把 ⌘W 从系统手里"借"过来。
///
/// 浮窗是不抢焦点的（.nonactivatingPanel），弹出来之后前台仍然是 Chrome/VS Code。
/// 这时候按 ⌘W，按键根本不路过我们，直接被前台 app 收走——tab 就这么没了，
/// 而你想关的明明是眼前这个浮窗。
///
/// 所以走 RegisterEventHotKey（BTT、Alfred 注册全局热键用的同一套系统机制）：
/// 注册期间这个组合键被系统直接截给我们，**前台 app 压根收不到**。
/// 浮窗一藏就注销，⌘W 立刻物归原主，该关 tab 关 tab。
/// 和读剪贴板一样，这条路不需要任何系统权限。
@MainActor
final class CloseHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: () -> Void = {}

    /// 浮窗露脸时调用。已经注册着的话只更新回调，不会重复注册。
    func register(onPress: @escaping () -> Void) {
        self.onPress = onPress
        guard hotKeyRef == nil else { return }

        // 接线只做一次：告诉 Carbon "我的热键按下了就来敲这个回调"
        if handlerRef == nil {
            var pressed = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    let hotKey = Unmanaged<CloseHotKey>.fromOpaque(userData).takeUnretainedValue()
                    // Carbon 的回调本来就在主线程，但补一跳，顺便让 MainActor 检查安心
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { hotKey.onPress() }
                    }
                    return noErr
                },
                1, &pressed,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )
        }

        let id = EventHotKeyID(signature: OSType(0x4E55_5453 /* 'NUTS' */), id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_W), UInt32(cmdKey), id,
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        // 注册不上（比如有别的程序把 ⌘W 占成了全局热键）就算了：
        // 主菜单里还有一条「关闭窗口 ⌘W」兜底，点过浮窗之后照样能关
        if status != noErr { hotKeyRef = nil }
    }

    /// 浮窗藏起来时调用，把 ⌘W 还给别的 app。
    func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    // 对象要没了，把挂在系统里的钩子全拆干净——不然 Carbon 手里
    // 还攥着这个已经死掉的对象的指针，下次按键就是悬空调用
    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
