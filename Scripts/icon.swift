import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let variants = [
    ("icp4", "16x16"), ("icp5", "32x32"), ("icp6", "32x32@2x"),
    ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"), ("ic10", "512x512@2x"),
    ("ic11", "16x16@2x"), ("ic12", "32x32@2x"), ("ic13", "128x128@2x"), ("ic14", "256x256@2x")
]
func length(_ value: Int) -> Data {
    var big = UInt32(value).bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
}
var contents = Data()
for (type, size) in variants {
    let png = try Data(contentsOf: directory.appendingPathComponent("icon_\(size).png"))
    contents.append(contentsOf: type.utf8)
    contents.append(length(png.count + 8))
    contents.append(png)
}
var file = Data("icns".utf8)
file.append(length(contents.count + 8))
file.append(contents)
try file.write(to: destination, options: .atomic)
