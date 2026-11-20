import AppKit

enum Ui {
    /// 現在のサンプリング周波数 (MainWindow が設定)
    static var fs: () -> Int = { 48000 }
    /// FFT用に最適化 で使うサンプル数
    static var fftN = 4096
    static let fftNs = [2048, 4096, 8192, 16384, 32768, 65536, 131072]

    static func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    static func popup(_ items: [String], width: CGFloat = 110) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        return p
    }

    static func button(_ t: String, _ target: AnyObject?, _ action: Selector?) -> NSButton {
        let b = NSButton(title: t, target: target, action: action)
        b.bezelStyle = .rounded
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    static func check(_ t: String, _ on: Bool, _ handler: @escaping (Bool) -> Void) -> NSButton {
        let b = ClosureButton(checkboxWithTitle: t, target: nil, action: nil)
        b.state = on ? .on : .off
        b.onClick = { handler($0.state == .on) }
        return b
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }
}

/// クロージャで動作するボタン
final class ClosureButton: NSButton {
    var onClick: ((NSButton) -> Void)? {
        didSet { target = self; action = #selector(fire) }
    }
    @objc private func fire() { onClick?(self) }
}

/// クロージャで動作するポップアップ
final class ClosurePopup: NSPopUpButton {
    var onChange: ((Int) -> Void)? {
        didSet { target = self; action = #selector(fire) }
    }
    @objc private func fire() { onChange?(indexOfSelectedItem) }

    static func make(_ items: [String], width: CGFloat = 110) -> ClosurePopup {
        let p = ClosurePopup(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        return p
    }
}

/// クロージャで動作するメニュー項目
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// 数値入力 (WinForms の NumericUpDown 相当: 範囲・小数桁・増減幅・▲▼)
/// 値の変更はユーザー操作時だけ onChange を呼ぶ (プログラムからの設定では呼ばない)
final class NumField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    let stepper = NSStepper()
    var minimum: Double { didSet { value = clamp(value) } }
    var maximum: Double { didSet { value = clamp(value) } }
    var decimals: Int { didSet { show() } }
    var increment: Double
    var onChange: (() -> Void)?
    /// 値が変わるたびに呼ぶ (増減幅の自動調整など)
    var onValueSet: (() -> Void)?
    private var _value: Double = 0

    var value: Double {
        get { _value }
        set { _value = clamp(round(newValue)); show(); onValueSet?() }
    }

    var isEnabled: Bool {
        get { field.isEnabled }
        set { field.isEnabled = newValue; stepper.isEnabled = newValue }
    }

    var warn = false {
        didSet { field.backgroundColor = warn ? NSColor(calibratedRed: 1, green: 0.89, blue: 0.88, alpha: 1) : .textBackgroundColor }
    }

    init(_ min: Double, _ max: Double, _ dec: Int, _ inc: Double, width: CGFloat = 92) {
        minimum = min; maximum = max; decimals = dec; increment = inc
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        field.drawsBackground = true
        field.translatesAutoresizingMaskIntoConstraints = false
        stepper.minValue = -1; stepper.maxValue = 1; stepper.integerValue = 0
        stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(step)
        stepper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field); addSubview(stepper)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            stepper.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 1),
            stepper.trailingAnchor.constraint(equalTo: trailingAnchor),
            stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalTo: field.heightAnchor),
        ])
        _value = clamp(0)
        show()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func round(_ v: Double) -> Double {
        let s = pow(10, Double(decimals))
        return (v * s).rounded() / s
    }
    private func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v.isFinite ? v : 0, minimum), maximum) }
    private func show() { field.stringValue = String(format: "%.\(decimals)f", _value) }

    private func userSet(_ v: Double) {
        let old = _value
        value = v
        if _value != old { onChange?() }
    }

    @objc private func commit() {
        let s = field.stringValue.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if let v = Double(s) { userSet(v) } else { show() }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commit() }

    @objc private func step() {
        let d = stepper.integerValue
        stepper.integerValue = 0
        commitIfEditing()
        userSet(_value + Double(d) * increment)
    }

    private func commitIfEditing() {
        if field.currentEditor() != nil, let v = Double(field.stringValue.replacingOccurrences(of: ",", with: "")) {
            _value = clamp(round(v))
        }
    }

    /// ↑↓ キーで増減
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.moveUp(_:)) { commitIfEditing(); userSet(_value + increment); return true }
        if sel == #selector(NSResponder.moveDown(_:)) { commitIfEditing(); userSet(_value - increment); return true }
        return false
    }

    /// 増減幅を値の桁に合わせる (1000 → 10 刻み)
    func autoInc() {
        let v = Swift.max(0.01, abs(_value))
        increment = Swift.max(pow(10, -Double(decimals)), pow(10, floor(log10(v)) - 2))
    }

    override var menu: NSMenu? {
        didSet { field.menu = menu; stepper.menu = menu }
    }
}

/// リンク風の単位表示 (クリックで切替、右クリックでメニュー)
final class UnitLink: NSTextField {
    var onClick: (() -> Void)?
    convenience init() {
        self.init(labelWithString: "")
        textColor = .linkColor
        setContentHuggingPriority(.required, for: .horizontal)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    var text: String = "" {
        didSet {
            attributedStringValue = NSAttributedString(string: text, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        }
    }
}
