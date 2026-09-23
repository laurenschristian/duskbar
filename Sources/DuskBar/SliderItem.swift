import AppKit

/// Menu row with a temperature slider and a swatch of the resulting white.
final class SliderItem: NSView {
    var onChange: ((Double, _ final: Bool) -> Void)?
    private let slider = NSSlider(value: 3400, minValue: 1200, maxValue: 6500, target: nil, action: nil)
    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")

    init(kelvin: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        slider.frame = NSRect(x: 20, y: 5, width: 150, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        swatch.frame = NSRect(x: 180, y: 7, width: 16, height: 16)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 8
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        label.frame = NSRect(x: 202, y: 6, width: 56, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        [slider, swatch, label].forEach(addSubview)
        set(kelvin)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func set(_ k: Double) {
        slider.doubleValue = k
        let c = Kelvin.rgb(k)
        swatch.layer?.backgroundColor = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        label.stringValue = "\(Int(k.rounded()))K"
    }

    @objc private func changed() {
        let k = (slider.doubleValue / 50).rounded() * 50
        set(k)
        onChange?(k, NSApp.currentEvent?.type == .leftMouseUp)
    }
}
