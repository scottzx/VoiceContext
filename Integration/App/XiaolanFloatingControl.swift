import SwiftUI
import UIKit
import Combine
import VoiceRecording

/// One scene-local native control stays above this app's own sheets and full-screen pages.
struct XiaolanFloatingControl: UIViewRepresentable {
    let recordings: VoiceRecordingWorkspace
    let visible: Bool
    let controlsEnabled: Bool

    func makeCoordinator() -> XiaolanFloatingCoordinator { XiaolanFloatingCoordinator(recordings: recordings) }
    func makeUIView(context: Context) -> XiaolanFloatingAnchor {
        let view = XiaolanFloatingAnchor()
        view.isUserInteractionEnabled = false
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ view: XiaolanFloatingAnchor, context: Context) {
        context.coordinator.visible = visible
        context.coordinator.controlsEnabled = controlsEnabled
        if let window = view.window { context.coordinator.attach(to: window) }
        context.coordinator.refresh()
    }
    static func dismantleUIView(_ view: XiaolanFloatingAnchor, coordinator: XiaolanFloatingCoordinator) { coordinator.tearDown() }
}

final class XiaolanFloatingAnchor: UIView {
    var attached: ((UIWindow) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A full-screen presentation may detach the presenting view temporarily.
        if let window { attached?(window) }
    }
}

@MainActor
final class XiaolanFloatingCoordinator: NSObject {
    private static let owners = NSMapTable<NSString, XiaolanFloatingCoordinator>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    private let recordings: VoiceRecordingWorkspace
    private let voice = XiaolanVoiceController.shared
    private weak var source: UIWindow?
    private var window: XiaolanFloatingWindow?
    private let root = XiaolanFloatingRoot()
    private let button = XiaolanFloatingButton(type: .system)
    private var subscriptions: Set<AnyCancellable> = []
    private var keyboardFrame: CGRect?
    private var dragStart = CGRect.zero
    private var dragging = false
    private var localAlert = false
    private var refreshQueued = false
    private var edge = XiaolanFloatingEdge(rawValue: UserDefaults.standard.string(forKey: "xiaolan.floating.edge") ?? "") ?? .right
    private var fraction: CGFloat = UserDefaults.standard.object(forKey: "xiaolan.floating.y") == nil ? 0.55 : UserDefaults.standard.double(forKey: "xiaolan.floating.y")
    private var tucked = UserDefaults.standard.bool(forKey: "xiaolan.floating.tucked")
    var visible = false
    var controlsEnabled = true

    init(recordings: VoiceRecordingWorkspace) {
        self.recordings = recordings
        super.init()
        root.backgroundColor = .clear
        root.accessibilityViewIsModal = false
        root.addSubview(button)
        root.layoutChanged = { [weak self] in self?.place() }
        button.accessibilityIdentifier = "xiaolan-floating-control"
        button.addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        let refresh: () -> Void = { [weak self] in self?.queueRefresh() }
        voice.objectWillChange.receive(on: DispatchQueue.main).sink { _ in refresh() }.store(in: &subscriptions)
        SessionLockStore.shared.objectWillChange.receive(on: DispatchQueue.main).sink { _ in refresh() }.store(in: &subscriptions)
        OffloadPermissionManager.shared.objectWillChange.receive(on: DispatchQueue.main).sink { _ in refresh() }.store(in: &subscriptions)
        ConfigConfirmationGate.shared.objectWillChange.receive(on: DispatchQueue.main).sink { _ in refresh() }.store(in: &subscriptions)
        FontSettings.shared.objectWillChange.receive(on: DispatchQueue.main).sink { _ in refresh() }.store(in: &subscriptions)
        SpeechCapsulePlacement.shared.$protectedRects
            .map { $0.filter { $0.key != "xiaolanFloating" } }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh() }
            .store(in: &subscriptions)
        let notifications = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UserDefaults.didChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            notifications.publisher(for: name).receive(on: DispatchQueue.main).sink { _ in refresh() }.store(in: &subscriptions)
        }
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            notifications.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] note in
                self?.keyboardFrame = name == UIResponder.keyboardWillHideNotification ? nil : note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                self?.queueRefresh()
            }.store(in: &subscriptions)
        }
    }

    func attach(to source: UIWindow) {
        guard source !== window, let scene = source.windowScene else { return }
        if self.source?.windowScene !== scene {
            tearDown()
            Self.owners.object(forKey: scene.session.persistentIdentifier as NSString)?.tearDown()
            Self.owners.setObject(self, forKey: scene.session.persistentIdentifier as NSString)
        }
        self.source = source
        refresh()
    }

    func tearDown() {
        if let key = source?.windowScene?.session.persistentIdentifier as NSString?, Self.owners.object(forKey: key) === self {
            Self.owners.removeObject(forKey: key)
        }
        removeWindow()
        source = nil
    }

    private func removeWindow() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        SpeechCapsulePlacement.shared.clearRect("xiaolanFloating")
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refreshQueued = false; self?.refresh() }
    }

    func refresh() {
        guard voice.isEnabled else { removeWindow(); return }
        guard mayDisplay, let source, let scene = source.windowScene else {
            window?.isHidden = true
            SpeechCapsulePlacement.shared.clearRect("xiaolanFloating")
            return
        }
        if window == nil {
            let overlay = XiaolanFloatingWindow(windowScene: scene)
            overlay.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            overlay.backgroundColor = .clear
            let controller = UIViewController()
            controller.view = root
            overlay.rootViewController = controller
            window = overlay
        }
        guard let window else { return }
        window.frame = source.frame
        let appearance = UserDefaults.standard.integer(forKey: "appearanceMode")
        window.overrideUserInterfaceStyle = appearance == 1 ? .light : appearance == 2 ? .dark : .unspecified
        window.traitOverrides.preferredContentSizeCategory = FontSettings.shared.effectiveAppContentSizeCategory
        configureButton()
        if dragging { placeDragged(button.frame) } else { place() }
    }

    private var mayDisplay: Bool {
        visible && voice.isEnabled && !localAlert && source?.windowScene?.activationState == .foregroundActive &&
            !SessionLockStore.shared.appIsLocked && OffloadPermissionManager.shared.pendingRequest == nil &&
            ConfigConfirmationGate.shared.pending == nil
    }

    private var shortStatus: String {
        if voice.status == "我在" { return "我在" }
        if voice.status == "收到，开始处理" { return "收到" }
        if voice.isPaused { return "暂停" }
        if voice.isSpeaking { return "播报" }
        if voice.isBusy { return voice.status.contains("识别") ? "识别" : "处理" }
        if voice.status == "正在听指令" || voice.status == "请说出指令" { return "聆听" }
        return "待机"
    }

    private func configureButton() {
        let symbol = voice.isPaused ? "mic.slash" : voice.isSpeaking ? "speaker.wave.2" : "mic"
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = tucked ? .clear : YimaDesign.UIKitColor.grouped
        configuration.baseForegroundColor = YimaDesign.UIKitColor.ink
        configuration.background.cornerRadius = YimaDesign.Radius.control
        configuration.cornerStyle = .fixed
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.imagePadding = 6
        configuration.titleLineBreakMode = .byTruncatingTail
        if !tucked {
            configuration.image = UIImage(systemName: symbol)
            var title = AttributedString(shortStatus)
            title.font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: window?.traitCollection)
            configuration.attributedTitle = title
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.configureTucked(tucked, edge: edge)
        button.showsMenuAsPrimaryAction = !tucked
        button.menu = tucked ? nil : controlMenu()
        button.accessibilityLabel = tucked ? "展开小蓝语音控制" : "小蓝语音模式"
        button.accessibilityValue = voice.status
        button.accessibilityHint = tucked ? "双击展开，可使用操作菜单移动" : "双击打开控制菜单，可拖动或使用操作菜单移动"
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "移到左侧", target: self, selector: #selector(moveLeft)),
            UIAccessibilityCustomAction(name: "移到右侧", target: self, selector: #selector(moveRight)),
            UIAccessibilityCustomAction(name: "向上移动", target: self, selector: #selector(moveUp)),
            UIAccessibilityCustomAction(name: "向下移动", target: self, selector: #selector(moveDown)),
            UIAccessibilityCustomAction(name: tucked ? "展开控制" : "贴边收起", target: self, selector: #selector(toggleTucked))
        ]
    }

    private func controlMenu() -> UIMenu {
        var actions: [UIMenuElement] = []
        if voice.isPaused {
            actions.append(UIAction(title: "继续语音模式", image: UIImage(systemName: "mic"), attributes: controlsEnabled ? [] : .disabled) { [weak self] _ in self?.resume() })
        } else {
            let canSpeak = controlsEnabled && !voice.isBusy && !voice.isSpeaking
            actions.append(UIAction(title: "点击说话", image: UIImage(systemName: "mic"), attributes: canSpeak ? [] : .disabled) { [weak self] _ in
                guard let self, self.controlsEnabled else { return }; self.voice.beginCommand()
            })
            actions.append(UIAction(title: "暂停语音模式", image: UIImage(systemName: "pause")) { [weak self] _ in self?.voice.pause() })
        }
        if voice.isSpeaking {
            actions.append(UIAction(title: "停止播报", image: UIImage(systemName: "speaker.slash")) { [weak self] _ in self?.voice.stopSpeaking() })
        }
        if let error = voice.error { actions.append(UIAction(title: error, attributes: .disabled) { _ in }) }
        actions.append(UIAction(title: "贴边收起", image: UIImage(systemName: edge == .left ? "chevron.left" : "chevron.right")) { [weak self] _ in self?.setTucked(true) })
        actions.append(UIAction(title: "关闭语音模式", image: UIImage(systemName: "mic.slash")) { [weak self] _ in self?.voice.disable() })
        return UIMenu(title: shortStatus, children: actions)
    }

    private func resume() {
        guard controlsEnabled, visible else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await voice.resume(recordings: recordings) }
            catch { presentFailure(error) }
        }
    }

    private func presentFailure(_ error: Error) {
        guard let source, source.windowScene?.activationState == .foregroundActive, !SessionLockStore.shared.appIsLocked else { return }
        var presenter = source.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        guard let presenter, !(presenter is UIAlertController) else { return }
        localAlert = true
        refresh()
        let alert = UIAlertController(title: "语音模式暂不可用", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            self?.localAlert = false
            self?.queueRefresh()
        })
        presenter.present(alert, animated: true)
    }

    private var movementBounds: CGRect {
        guard let source else { return .zero }
        let safe = source.safeAreaInsets
        return CGRect(x: safe.left + 8, y: safe.top + 52,
                      width: max(0, source.bounds.width - safe.left - safe.right - 16),
                      height: max(0, source.bounds.height - safe.top - safe.bottom - 108))
    }

    private var keyboard: CGRect? { keyboardFrame.flatMap { source?.convert($0, from: nil) } }

    private var protectedFrames: [CGRect] {
        guard let source, let window else { return [] }
        return SpeechCapsulePlacement.shared.protectedRects.compactMap { key, frame in
            guard key != "xiaolanFloating" else { return nil }
            return key == "keyboard" ? source.convert(frame, from: nil) : source.convert(frame, to: window)
        }
    }

    private func place() {
        guard let window, mayDisplay, !dragging else { return }
        let fitted = button.sizeThatFits(CGSize(width: min(260, movementBounds.width), height: .greatestFiniteMagnitude))
        let size = tucked ? CGSize(width: 44, height: 44) : CGSize(width: max(44, fitted.width), height: max(44, fitted.height))
        guard let frame = XiaolanFloatingGeometry.frame(in: movementBounds, size: size, edge: edge, fraction: fraction,
                                                       keyboard: keyboard, protected: protectedFrames) else {
            window.isHidden = true
            SpeechCapsulePlacement.shared.clearRect("xiaolanFloating")
            return
        }
        button.frame = frame
        window.isHidden = false
        SpeechCapsulePlacement.shared.setRect("xiaolanFloating", frame)
    }

    private func placeDragged(_ proposed: CGRect) {
        guard let window, mayDisplay else { return }
        guard let frame = XiaolanFloatingGeometry.clamp(proposed, to: movementBounds, keyboard: keyboard, protected: protectedFrames) else {
            window.isHidden = true
            SpeechCapsulePlacement.shared.clearRect("xiaolanFloating")
            return
        }
        button.frame = frame
        window.isHidden = false
        SpeechCapsulePlacement.shared.setRect("xiaolanFloating", frame)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(edge.rawValue, forKey: "xiaolan.floating.edge")
        defaults.set(Double(fraction), forKey: "xiaolan.floating.y")
        defaults.set(tucked, forKey: "xiaolan.floating.tucked")
    }

    private func setTucked(_ value: Bool) {
        tucked = value
        persist()
        configureButton()
        if UIAccessibility.isReduceMotionEnabled { place() }
        else { UIView.animate(withDuration: 0.2) { self.place() } }
    }

    @objc private func tapped() { if tucked { setTucked(false) } }
    @objc private func moveLeft() -> Bool { edge = .left; persist(); refresh(); return true }
    @objc private func moveRight() -> Bool { edge = .right; persist(); refresh(); return true }
    @objc private func moveUp() -> Bool { fraction = max(0, fraction - 0.15); persist(); refresh(); return true }
    @objc private func moveDown() -> Bool { fraction = min(1, fraction + 0.15); persist(); refresh(); return true }
    @objc private func toggleTucked() -> Bool { setTucked(!tucked); return true }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            if tucked { setTucked(false) }
            dragging = true
            dragStart = button.frame
        case .changed:
            let translation = gesture.translation(in: root)
            let proposed = dragStart.offsetBy(dx: translation.x, dy: translation.y)
            placeDragged(proposed)
        case .ended:
            let translation = gesture.translation(in: root)
            let centerX = dragStart.midX + translation.x
            edge = XiaolanFloatingGeometry.edge(centerX: centerX, in: movementBounds)
            fraction = XiaolanFloatingGeometry.fraction(centerY: button.frame.midY, height: button.frame.height, in: movementBounds)
            dragging = false
            setTucked(XiaolanFloatingGeometry.shouldTuck(centerX: centerX, in: movementBounds))
        case .cancelled, .failed:
            dragging = false
            place()
        default: break
        }
    }
}

private final class XiaolanFloatingWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === rootViewController?.view ? nil : hit
    }
}

private final class XiaolanFloatingRoot: UIView {
    var layoutChanged: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); layoutChanged?() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

private final class XiaolanFloatingButton: UIButton {
    private let handle = UIView()
    private let chevron = UIImageView()
    private var edge = XiaolanFloatingEdge.right

    override init(frame: CGRect) {
        super.init(frame: frame)
        handle.isUserInteractionEnabled = false
        handle.backgroundColor = YimaDesign.UIKitColor.grouped
        handle.layer.cornerRadius = 7
        chevron.tintColor = YimaDesign.UIKitColor.ink
        chevron.contentMode = .scaleAspectFit
        handle.addSubview(chevron)
        addSubview(handle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configureTucked(_ tucked: Bool, edge: XiaolanFloatingEdge) {
        self.edge = edge
        handle.isHidden = !tucked
        chevron.image = UIImage(systemName: edge == .left ? "chevron.compact.right" : "chevron.compact.left")
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        handle.frame = CGRect(x: edge == .left ? 0 : bounds.width - 14, y: 0, width: 14, height: bounds.height)
        chevron.frame = handle.bounds.insetBy(dx: 1, dy: 12)
    }
}
