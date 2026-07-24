import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("Usage: build-icns.swift <iconset-directory> <output.icns>\n".utf8)
    )
    exit(64)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let representations = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndianValue = value.bigEndian
    withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
}

var body = Data()
for (type, filename) in representations {
    let sourceURL = iconsetURL.appendingPathComponent(filename)
    let imageData = try Data(contentsOf: sourceURL)
    body.append(contentsOf: type.utf8)
    appendBigEndian(UInt32(imageData.count + 8), to: &body)
    body.append(imageData)
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(body.count + 8), to: &icns)
icns.append(body)
try icns.write(to: outputURL, options: .atomic)
