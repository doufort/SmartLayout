import Carbon

/// Глобальные горячие клавиши через Carbon RegisterEventHotKey.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers = [UInt32: () -> Void]()
    private var refs = [UInt32: EventHotKeyRef]()
    private var installed = false

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534C4159), id: id)
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs[id] = ref
            handlers[id] = handler
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotKeyID {
    static let fix: UInt32 = 1       // ⌥⇧F — исправить текст
    static let improve: UInt32 = 2   // ⌥⇧I — улучшить текст
    static let accept: UInt32 = 3    // ⌥↩ — принять исправление
    static let acceptAlternative: UInt32 = 4  // ⌥⇧↩ — принять вариант формулировки
    static let acceptNext: UInt32 = 5         // ⌥⇥ — дописать предложенное продолжение
}
