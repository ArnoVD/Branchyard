import Foundation
import BranchyardArt

// Writes an .iconset folder for `iconutil`. Usage: IconRenderer <out.iconset>
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try AppIconArt.png(pixels: base * scale)!.write(to: out.appendingPathComponent(name))
    }
}
print("Wrote \(out.path)")
