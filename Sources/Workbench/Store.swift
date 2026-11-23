import Foundation
import CSQLite
import CryptoKit
import MusicCore

enum WorkError: LocalizedError {
    case database(String), audio(String), files, portability, selectPhrase
    var errorDescription: String? {
        switch self {
        case .database(let message): "SQLite · \(message)"
        case .audio(let message): message
        case .files: "O áudio associado ao projeto está indisponível."
        case .portability: "O pacote é incompatível ou seu áudio não corresponde ao projeto."
        case .selectPhrase: "Escolha uma proposta de solo primeiro."
        }
    }
}

final class Store {
    private static let schemaVersion = 2
    static let audioName = "recording.wav"
    static let sourceExtensions = ["mp3", "wav", "m4a", "aiff", "flac", "caf", "aac"]
    static let analysisVersion = 2
    let folder: URL
    private let handle: OpaquePointer
    private var openedVersion = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(folder: URL, existingOnly: Bool = false) throws {
        self.folder = folder
        let manager = FileManager.default
        if !existingOnly { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
        var pointer: OpaquePointer?
        let db = folder.appendingPathComponent("projects.sqlite3")
        let flags = existingOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(db.path, &pointer, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw WorkError.database("Não foi possível abrir o banco.")
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
        do {
            let version = try statement("PRAGMA user_version") { query -> Int in
                guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
                return Int(sqlite3_column_int(query, 0))
            }
            if (0...1).contains(version) && !existingOnly {
                try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, name TEXT NOT NULL, updated REAL NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS analyses(cache_key TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS removed_projects(id TEXT PRIMARY KEY, removed_at REAL NOT NULL);
                PRAGMA user_version = 2;
                COMMIT;
                """)
                openedVersion = Self.schemaVersion
            } else if version == Self.schemaVersion || (version == 1 && existingOnly) {
                openedVersion = version
            } else {
                throw WorkError.database("Versão de projeto incompatível (\(version)).")
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }
    deinit { sqlite3_close(handle) }

    static func standard() throws -> Store {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try Store(folder: base.appendingPathComponent("SoloForgeCommunity", isDirectory: true))
    }
    func audio(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString).appendingPathComponent(Self.audioName) }

    func save(_ project: Project) throws {
        try Music.validate(project)
        let data = try encoder.encode(project)
        try statement("""
            INSERT INTO projects(id,name,updated,payload) VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name,updated=excluded.updated,payload=excluded.payload
            """) { query in
            bind(project.id.uuidString, to: query, at: 1)
            bind(project.name, to: query, at: 2)
            sqlite3_bind_double(query, 3, Date().timeIntervalSince1970)
            bind(data, to: query, at: 4)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    func list(removed: Bool = false) throws -> [Project] {
        let query: String
        if openedVersion < 2 {
            if removed { return [] }
            query = "SELECT payload FROM projects ORDER BY updated DESC"
        } else if removed {
            query = "SELECT p.payload FROM removed_projects r JOIN projects p USING(id) ORDER BY r.removed_at DESC"
        } else {
            query = "SELECT p.payload FROM projects p LEFT JOIN removed_projects r USING(id) WHERE r.id IS NULL ORDER BY p.updated DESC"
        }
        return try statement(query) { query in
            var result: [Project] = []
            while true {
                switch sqlite3_step(query) {
                case SQLITE_ROW: result.append(try decoder.decode(Project.self, from: blob(query, at: 0)))
                case SQLITE_DONE: return result
                default: throw failure()
                }
            }
        }
    }

    func setRemoved(_ project: Project, _ removed: Bool) throws {
        let sql = removed
            ? "INSERT OR IGNORE INTO removed_projects(id,removed_at) SELECT id,?2 FROM projects WHERE id=?1"
            : "DELETE FROM removed_projects WHERE id=?1"
        try statement(sql) { query in
            bind(project.id.uuidString, to: query, at: 1)
            if removed { sqlite3_bind_double(query, 2, Date().timeIntervalSince1970) }
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    func deleteRemovedProject(_ id: UUID) throws {
        // Commit the user's decision before touching audio. A stopped or failed
        // deletion stays in Removed for retry and cannot be restored halfway.
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS purged_projects(id TEXT PRIMARY KEY);
                CREATE TRIGGER IF NOT EXISTS prevent_purged_save BEFORE INSERT ON projects
                WHEN EXISTS(SELECT 1 FROM purged_projects WHERE id=NEW.id)
                BEGIN SELECT RAISE(ABORT,'Este projeto foi excluído.'); END;
                CREATE TRIGGER IF NOT EXISTS prevent_purged_restore BEFORE DELETE ON removed_projects
                WHEN EXISTS(SELECT 1 FROM purged_projects WHERE id=OLD.id)
                 AND EXISTS(SELECT 1 FROM projects WHERE id=OLD.id)
                BEGIN SELECT RAISE(ABORT,'Confirme a exclusão novamente para concluir.'); END;
                """)
            try executeForProject("INSERT OR IGNORE INTO purged_projects SELECT id FROM removed_projects WHERE id=?1", id)
            let authorized = try statement("SELECT 1 FROM purged_projects WHERE id=?1") { query in
                bind(id.uuidString, to: query, at: 1)
                return sqlite3_step(query) == SQLITE_ROW
            }
            guard authorized else { throw WorkError.database("Só é possível excluir um projeto que esteja em Removidos.") }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }

        try execute("BEGIN IMMEDIATE")
        do {
            let assets = audio(for: id).deletingLastPathComponent()
            do { try FileManager.default.removeItem(at: assets) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { /* Already removed. */ }
            // The analysis cache is shared by copies of the same recording.
            try executeForProject("""
                DELETE FROM analyses WHERE substr(cache_key,instr(cache_key,':')+1) =
                  (SELECT json_extract(CAST(payload AS TEXT),'$.sourceHash') FROM projects WHERE id=?1)
                AND NOT EXISTS (
                  SELECT 1 FROM projects WHERE id<>?1 AND json_extract(CAST(payload AS TEXT),'$.sourceHash') =
                    substr(analyses.cache_key,instr(analyses.cache_key,':')+1)
                )
                """, id)
            try executeForProject("DELETE FROM projects WHERE id=?1", id)
            try executeForProject("DELETE FROM removed_projects WHERE id=?1", id)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func executeForProject(_ sql: String, _ id: UUID) throws {
        try statement(sql) { query in
            bind(id.uuidString, to: query, at: 1)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    func cached(_ hash: String) throws -> AudioMap? {
        try statement("SELECT payload FROM analyses WHERE cache_key=?") { query in
            bind("\(Self.analysisVersion):\(hash)", to: query, at: 1)
            switch sqlite3_step(query) {
            case SQLITE_ROW: return try decoder.decode(AudioMap.self, from: blob(query, at: 0))
            case SQLITE_DONE: return nil
            default: throw failure()
            }
        }
    }

    func cache(_ map: AudioMap, hash: String) throws {
        try statement("INSERT OR REPLACE INTO analyses(cache_key,payload) VALUES(?,?)") { query in
            bind("\(Self.analysisVersion):\(hash)", to: query, at: 1)
            bind(try encoder.encode(map), to: query, at: 2)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    func install(_ project: Project, stagedFolder: URL) throws {
        let destination = audio(for: project.id).deletingLastPathComponent()
        try FileManager.default.moveItem(at: stagedFolder, to: destination)
        do { try save(project) }
        catch {
            try? FileManager.default.moveItem(at: destination, to: stagedFolder)
            throw error
        }
    }

    func export(_ project: Project, to destination: URL) throws {
        let fm = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let portable = try Store(folder: stage)
        let assets = portable.audio(for: project.id).deletingLastPathComponent()
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let originalFolder = audio(for: project.id).deletingLastPathComponent()
        let original = try Self.original(in: originalFolder)
        try fm.copyItem(at: original, to: assets.appendingPathComponent(original.lastPathComponent))
        try portable.save(project)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: stage)
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
    }

    static func original(in directory: URL) throws -> URL {
        for ext in sourceExtensions {
            let file = directory.appendingPathComponent("source.\(ext)")
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true, values?.isSymbolicLink == false { return file }
        }
        throw WorkError.files
    }

    func importPortable(_ source: URL, progress: (Double) -> Void) throws -> Project {
        let portable = try Store(folder: source, existingOnly: true)
        let items = try portable.list()
        guard items.count == 1, var project = items.first else { throw WorkError.portability }
        try Music.validate(project)
        let original = try Self.original(in: portable.audio(for: project.id).deletingLastPathComponent())
        let manager = FileManager.default
        let staging = folder.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(original.lastPathComponent)
        guard try Self.digest(copying: original, to: copy, progress: { progress($0 * 0.30) }) == project.sourceHash else { throw WorkError.portability }
        let decoded = staging.appendingPathComponent(Self.audioName)
        let actual = try AudioFiles.decode(copy, to: decoded, progress: { progress(0.30 + $0 * 0.68) })
        guard abs(actual - project.map.duration) < 0.05 else { throw WorkError.portability }
        project.id = UUID()
        try install(project, stagedFolder: staging)
        progress(1)
        return project
    }

    static func digest(copying source: URL, to destination: URL, progress: (Double) -> Void) throws -> String {
        let total = Double(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard total > 0 else { throw WorkError.files }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var sha = SHA256()
        var count = 0
        while let block = try input.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            sha.update(data: block)
            try output.write(contentsOf: block)
            count += block.count
            progress(min(1, Double(count) / total))
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private func bind(_ value: String, to query: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(query, index, $0, -1, transient) }
    }
    private func bind(_ value: Data, to query: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(query, index, $0.baseAddress, Int32($0.count), transient) }
    }
    private func blob(_ query: OpaquePointer, at index: Int32) -> Data {
        guard let base = sqlite3_column_blob(query, index) else { return Data() }
        return Data(bytes: base, count: Int(sqlite3_column_bytes(query, index)))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement<T>(_ sql: String, _ work: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        return try work(pointer)
    }
    private func failure() -> WorkError { .database(String(cString: sqlite3_errmsg(handle))) }
}

enum Importer {
    static func importAudio(_ url: URL, name: String, store: Store, progress: @escaping (Double) -> Void) throws -> Project {
        let ext = url.pathExtension.lowercased()
        guard Store.sourceExtensions.contains(ext) else { throw WorkError.audio("Selecione um MP3 ou WAV compatível.") }
        let stage = store.folder.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let copied = stage.appendingPathComponent("source.\(ext)")
        let hash = try Self.stage("Copiar gravação") { try Store.digest(copying: url, to: copied) { progress($0 * 0.15) } }
        let decoded = stage.appendingPathComponent(Store.audioName)
        let duration = try Self.stage("Decodificar gravação") { try AudioFiles.decode(copied, to: decoded) { progress(0.15 + $0 * 0.35) } }
        let cached = try store.cached(hash)
        let map: AudioMap
        if let cached, abs(cached.duration - duration) < 0.05 {
            map = cached
        } else {
            var scanned = try Self.stage("Analisar gravação") { try Analyzer.analyze(decoded) { progress(0.5 + $0 * 0.40) } }
            scanned.vocalHints = try VocalAnalysis.detect(in: decoded, duration: duration) { progress(0.90 + $0 * 0.08) }
            map = scanned
            try store.cache(map, hash: hash)
        }
        try Task.checkCancellation()
        let project = Project(name: name, sourceHash: hash, map: map)
        try Self.stage("Gravar projeto") { try store.install(project, stagedFolder: stage) }
        progress(1)
        return project
    }
    private static func stage<T>(_ name: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch is CancellationError { throw CancellationError() }
        catch { throw WorkError.audio("\(name) · \(error.localizedDescription)") }
    }
}
