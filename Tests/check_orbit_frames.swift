import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func load(_ name: String) -> NSBitmapImageRep {
    let url = directory.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url),
          let original = NSBitmapImageRep(data: data),
          let bitmap = original.converting(to: .deviceRGB, renderingIntent: .default) else {
        fail("Cannot read screenshot \(name)")
    }
    guard bitmap.pixelsWide == 828, bitmap.pixelsHigh == 1792 else {
        fail("Unexpected screenshot dimensions for \(name)")
    }
    return bitmap
}

let pairs = [
    ("normal", "installed-four-modules.png", "activity-orbit-next-frame.png"),
    ("Reduce Motion enabled", "reduced-motion-first.png", "reduced-motion-next.png"),
    ("foreground resume", "resumed-motion-first.png", "resumed-motion-next.png")
]
for (scenario, firstName, nextName) in pairs {
    let first = load(firstName)
    let next = load(nextName)
    var changedPixels = 0
    var coloredMotionPixels = 0
    // Same iPhone-11 geometry as the reference: only the activity border,
    // excluding status bar, charging icon, tab tint and module controls.
    for y in 465..<610 {
        for x in 20..<810 {
            guard let a = first.colorAt(x: x, y: y),
                  let b = next.colorAt(x: x, y: y) else { continue }
            let delta = max(abs(a.redComponent - b.redComponent),
                            abs(a.greenComponent - b.greenComponent),
                            abs(a.blueComponent - b.blueComponent))
            if delta > 8.0 / 255.0 {
                changedPixels += 1
                let channels = [a.redComponent, a.greenComponent, a.blueComponent]
                if channels.max()! - channels.min()! > 5.0 / 255.0 {
                    coloredMotionPixels += 1
                }
            }
        }
    }
    guard changedPixels > 150 else { fail("Orbit frozen in \(scenario): \(changedPixels) moving pixels") }
    guard coloredMotionPixels < max(10, changedPixels / 100) else {
        fail("Colored light remains in \(scenario)")
    }
    print("PASS: \(scenario): \(changedPixels) moving grayscale pixels")
}
_ = load("installed-single-module.png")
print("PASS: native orbit moves normally, with Reduce Motion, and after foreground resume")
