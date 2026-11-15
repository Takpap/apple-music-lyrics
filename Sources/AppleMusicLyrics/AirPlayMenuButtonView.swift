import AppKit

/// The AirPlay button in the full-screen player. A click asks Music for its
/// outputs and shows them as a menu; choosing one toggles it, the way Music's
/// own AirPlay menu works (several outputs can play at once, at least one
/// stays on). The icon turns blue while Music plays to something other than
/// this Mac.
@MainActor
final class AirPlayMenuButtonView: NSButton {
    private unowned let model: ImmersiveLyricsModel
    private var devices: [MusicAirPlayDevice] = []
    private var loading = false

    init(model: ImmersiveLyricsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "AirPlay")?
            .withSymbolConfiguration(configuration)
        toolTip = "AirPlay"
        setAccessibilityLabel("AirPlay")
        target = self
        action = #selector(showMenu)
        updateTint(active: false)
        model.fetchAirPlayDevices { [weak self] devices in self?.apply(devices) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateTint(active: Bool) {
        contentTintColor = active ? .systemBlue : NSColor.white.withAlphaComponent(0.85)
    }

    private func apply(_ devices: [MusicAirPlayDevice]) {
        self.devices = devices
        updateTint(active: devices.contains { $0.selected && !$0.isComputer })
    }

    @objc private func showMenu() {
        guard !loading else { return }
        loading = true
        model.fetchAirPlayDevices { [weak self] devices in
            guard let self else { return }
            self.loading = false
            self.apply(devices)
            self.popUp(self.makeMenu())
        }
    }

    private func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 6), in: self)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        let header = NSMenuItem(title: "AirPlay", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if devices.isEmpty {
            let empty = NSMenuItem(title: "Music isn’t open", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for device in devices {
            let item = NSMenuItem(title: Self.displayName(device), action: #selector(toggleDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.name
            item.state = device.selected ? .on : .off
            item.isEnabled = device.available
            item.image = NSImage(systemSymbolName: Self.symbol(for: device), accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Music", action: #selector(openMusic), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var selected = devices.filter(\.selected).map(\.name)
        if let index = selected.firstIndex(of: name) {
            guard selected.count > 1 else { return }
            selected.remove(at: index)
        } else {
            selected.append(name)
        }
        model.setAirPlayDevices(named: selected) { [weak self] in
            self?.model.fetchAirPlayDevices { devices in self?.apply(devices) }
        }
    }

    @objc private func openMusic() { model.openMusic() }

    static func displayName(_ device: MusicAirPlayDevice) -> String {
        // Music reports the Mac's own speakers under a placeholder name.
        if device.isComputer { return Host.current().localizedName ?? "This Mac" }
        return device.name
    }

    static func symbol(for device: MusicAirPlayDevice) -> String {
        switch device.kind {
        case "computer": return "laptopcomputer"
        case "homepod": return "homepod.fill"
        case "apple tv": return "appletv.fill"
        case "airport express": return "hifispeaker.fill"
        case "bluetooth device": return "headphones"
        case "tv": return "tv"
        default: return "hifispeaker.fill"
        }
    }
}
