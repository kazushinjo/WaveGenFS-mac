import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController!
    private var pendingOpen: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        main = MainWindowController()
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let u = pendingOpen { main.loadParamFile(u); pendingOpen = nil }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        if main == nil { pendingOpen = u } else { main.loadParamFile(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { main?.shutdown() }

    @objc func togglePlay() { main.togglePlay() }
    @objc func openParam() { main.openParamFile() }
    @objc func saveParam() { main.saveParamFile() }
    @objc func saveWav() { main.saveWav() }
    @objc func toggleHide() { main.toggleHide() }

    private func buildMenu() {
        let bar = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            top.submenu = m
            bar.addItem(top)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            if let t = target { i.target = t }
            return i
        }
        sub("WaveGenFS", [
            item("WaveGenFS について", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("WaveGenFS を隠す", #selector(NSApplication.hide(_:)), "h"),
            item("ほかを隠す", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("すべてを表示", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("WaveGenFS を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("ファイル", [
            item("設定を開く...", #selector(openParam), "o", target: self),
            item("設定を保存...", #selector(saveParam), "s", target: self),
            .separator(),
            item("WAV を保存...", #selector(saveWav), "e", target: self),
            .separator(),
            item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
        ])
        sub("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
        ])
        sub("再生", [
            item("再生 / 停止  (F5)", #selector(togglePlay), "r", target: self),
        ])
        sub("表示", [
            item("全画面  (F11)", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            item("波形のみ  (F12)", #selector(toggleHide), "l", target: self),
        ])
        let win = [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大/縮小", #selector(NSWindow.performZoom(_:)), ""),
        ]
        sub("ウインドウ", win)
        NSApp.windowsMenu = bar.items.last?.submenu
        NSApp.mainMenu = bar
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
