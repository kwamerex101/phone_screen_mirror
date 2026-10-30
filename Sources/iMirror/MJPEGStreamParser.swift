import Foundation

/// Incremental parser for WDA's fixed multipart stream. Limits apply before
/// image decoding so a corrupt local peer cannot grow an unbounded buffer.
struct MJPEGStreamParser {
    enum ParseError: Error { case oversizedHeaders, invalidContentLength }
    static let maximumHeaderBytes = 16 * 1024
    static let maximumFrameBytes = 8 * 1024 * 1024
    private static let boundary = Data("--BoundaryString".utf8)
    private static let terminator = Data("\r\n\r\n".utf8)
    private var buffer = Data()
    private var consumedResponseHeaders = false
    private var payloadLength: Int?

    /// The caller decodes only the newest complete frame in each receive batch.
    /// Partial final frames remain buffered, without hiding the last complete one.
    mutating func append(_ bytes: Data) throws -> Data? {
        buffer.append(bytes)
        var cursor = buffer.startIndex
        var newest: Data?
        defer { buffer.removeSubrange(buffer.startIndex..<cursor) }
        if !consumedResponseHeaders {
            guard let end = buffer.range(of: Self.terminator, in: cursor..<buffer.endIndex) else {
                guard buffer.count <= Self.maximumHeaderBytes else { throw ParseError.oversizedHeaders }
                return nil
            }
            guard end.upperBound - cursor <= Self.maximumHeaderBytes else { throw ParseError.oversizedHeaders }
            cursor = end.upperBound
            consumedResponseHeaders = true
        }
        while true {
            if let length = payloadLength {
                guard buffer.endIndex - cursor >= length else { return newest }
                newest = Data(buffer[cursor..<(cursor + length)])
                cursor += length
                payloadLength = nil
            }
            guard let boundary = buffer.range(of: Self.boundary, in: cursor..<buffer.endIndex) else {
                guard buffer.endIndex - cursor <= Self.maximumHeaderBytes else { throw ParseError.oversizedHeaders }
                return newest
            }
            guard boundary.lowerBound - cursor <= Self.maximumHeaderBytes else { throw ParseError.oversizedHeaders }
            guard let end = buffer.range(of: Self.terminator, in: boundary.upperBound..<buffer.endIndex) else {
                guard buffer.endIndex - cursor <= Self.maximumHeaderBytes else { throw ParseError.oversizedHeaders }
                return newest
            }
            guard end.upperBound - cursor <= Self.maximumHeaderBytes else { throw ParseError.oversizedHeaders }
            let headers = String(decoding: buffer[boundary.upperBound..<end.lowerBound], as: UTF8.self)
            let lengths = headers.components(separatedBy: "\r\n").compactMap { line -> String? in
                let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2,
                      fields[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                return fields[1].trimmingCharacters(in: .whitespaces)
            }
            guard lengths.count == 1, let raw = lengths.first, !raw.isEmpty,
                  raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let length = Int(raw), length > 0, length <= Self.maximumFrameBytes else {
                throw ParseError.invalidContentLength
            }
            payloadLength = length
            cursor = end.upperBound
        }
    }
}
