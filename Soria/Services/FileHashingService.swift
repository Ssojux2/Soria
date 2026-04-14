import CryptoKit
import Foundation

enum FileHashingService {
    static func contentHash(for fileURL: URL) -> String {
        // 한국어: 대용량 파일 성능을 위해 앞/뒤 블록과 파일 크기를 함께 해시합니다.
        let blockSize = 256 * 1024
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return UUID().uuidString }
        defer { try? handle.close() }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let head = (try? handle.read(upToCount: blockSize)) ?? Data()
        let tail: Data
        if fileSize > Int64(blockSize) {
            try? handle.seek(toOffset: UInt64(max(0, fileSize - Int64(blockSize))))
            tail = (try? handle.read(upToCount: blockSize)) ?? Data()
        } else {
            tail = Data()
        }

        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: tail)
        hasher.update(data: withUnsafeBytes(of: fileSize.bigEndian) { Data($0) })
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
