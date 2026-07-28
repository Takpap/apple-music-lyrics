import Carbon
import Foundation

final class GlobalHotKeyController {
    private enum HotKeyID: UInt32 {
        case toggleFloating = 1
        case toggleLock = 2
    }

    private static let signature: OSType = 0x414D4C59 // AMLY

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    var onToggleFloating: (() -> Void)?
    var onToggleLock: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                let controller = Unmanaged<GlobalHotKeyController>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return controller.handle(event)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        register(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(controlKey | optionKey),
            id: .toggleFloating
        )
        register(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey),
            id: .toggleLock
        )
    }

    deinit {
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: HotKeyID) {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id.rawValue)
        guard RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        ) == noErr,
        let reference else { return }
        hotKeys.append(reference)
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == Self.signature,
              let id = HotKeyID(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }
        switch id {
        case .toggleFloating: onToggleFloating?()
        case .toggleLock: onToggleLock?()
        }
        return noErr
    }
}
