import Foundation
import Security
import Testing
@testable import Workbench

@Test func savingAndReplacingAKeyCanBeVerifiedInAnIsolatedKeychain() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var storage: SecKeychain?
    let password = Array(UUID().uuidString.utf8)
    let status = password.withUnsafeBytes { bytes in
        SecKeychainCreate(folder.appendingPathComponent("test.keychain").path, UInt32(bytes.count),
                          bytes.baseAddress, false, nil, &storage)
    }
    try #require(status == errSecSuccess)
    let keychain = try #require(storage)
    defer { SecKeychainDelete(keychain) }
    let vault = KeyVault(keychain: keychain)
    #expect(try vault.read() == nil)
    for _ in 0..<2 {
        let dummy = "sk-test-" + UUID().uuidString
        try vault.save(dummy)
        let matches = try vault.read() == dummy
        #expect(matches)
    }
    #expect(throws: DirectionError.self) { try vault.save("inválida") }
    try vault.remove()
    #expect(try vault.read() == nil)
}
