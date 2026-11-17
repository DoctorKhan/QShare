import Foundation

/// Where incoming files are written while in flight, and how they are named when finished.
///
/// In-flight data lives in a hidden folder inside the destination so the final move is an
/// atomic rename on the same volume. A file the sender identifies with a stable hash keeps a
/// stable in-flight name, which is what lets a later attempt continue it.
struct FileStore {
    static let partialFolderName = ".qshare-incoming"
    static let partialLifetime: TimeInterval = 24 * 60 * 60

    let destination: URL

    var partialFolder: URL {
        destination.appendingPathComponent(Self.partialFolderName, isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
    }

    /// In-flight location for a file. Stable across attempts when the sender supplies a hash.
    func partialURL(for file: IncomingFile) -> URL {
        let name: String
        if file.attachmentHash != 0 {
            let nameHash = Self.fnv1a(file.name)
            name = "\(UInt64(bitPattern: file.attachmentHash))-\(file.size)-\(nameHash).part"
        } else {
            name = "\(UUID().uuidString).part"
        }
        return partialFolder.appendingPathComponent(name)
    }

    /// Size of a usable earlier partial for this file, or 0.
    func resumableSize(for file: IncomingFile) -> Int64 {
        guard file.attachmentHash != 0, file.size > 0 else { return 0 }
        let url = partialURL(for: file)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return 0 }
        guard size > 0, size < file.size, Date().timeIntervalSince(modified) < Self.partialLifetime else {
            return 0
        }
        return size
    }

    /// Moves a finished file into the destination under a name that doesn't clobber anything.
    func finalize(partial: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let clean = Self.sanitize(name)
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension
        for attempt in 0..<10_000 {
            let candidateName: String
            if attempt == 0 {
                candidateName = clean
            } else {
                candidateName = ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
            }
            let candidate = destination.appendingPathComponent(candidateName)
            if fm.fileExists(atPath: candidate.path) { continue }
            do {
                try fm.moveItem(at: partial, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw QSError.io("Could not find a free file name for \(clean)")
    }

    /// Removes stale in-flight files, and the folder itself once it is empty.
    func cleanUp() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: partialFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        var remaining = items.count
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) >= Self.partialLifetime {
                try? fm.removeItem(at: item)
                remaining -= 1
            }
        }
        if remaining == 0 { try? fm.removeItem(at: partialFolder) }
    }

    func availableBytes() -> Int64? {
        let values = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Reduces a sender-supplied name to a single safe path component.
    static func sanitize(_ name: String) -> String {
        var component = name.replacingOccurrences(of: "\\", with: "/")
        component = (component as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/:\0").union(.controlCharacters).union(.newlines)
        component = String(String.UnicodeScalarView(component.unicodeScalars.map {
            forbidden.contains($0) ? "_" : $0
        }))
        while component.hasPrefix(".") { component.removeFirst() }
        component = component.trimmingCharacters(in: .whitespaces)
        if component.isEmpty { component = "Received File" }
        // Keep within the 255-byte file name limit, leaving room for a " (n)" suffix.
        let ext = (component as NSString).pathExtension
        var base = (component as NSString).deletingPathExtension
        let budget = 230 - ext.utf8.count
        while base.utf8.count > max(1, budget) { base.removeLast() }
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
