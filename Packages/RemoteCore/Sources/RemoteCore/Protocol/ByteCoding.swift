import Foundation

/// ビッグエンディアンでバイト列を組み立てる。
struct ByteWriter {
    private(set) var data = Data()

    mutating func write(_ value: UInt8) { data.append(value) }
    mutating func write(_ value: UInt16) { append(value.bigEndian) }
    mutating func write(_ value: UInt32) { append(value.bigEndian) }
    mutating func write(_ value: UInt64) { append(value.bigEndian) }
    mutating func write(_ value: Float) { write(value.bitPattern) }
    mutating func write(_ value: Bool) { write(value ? UInt8(1) : UInt8(0)) }
    mutating func write(_ bytes: Data) { data.append(bytes) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}

/// ビッグエンディアンのバイト列を読む。
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data) // 添字を 0 から始まるようにそろえる
        self.offset = 0
    }

    var remainingCount: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remainingCount >= 1 else { throw RemoteCoreError.truncatedData }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 { try readInteger() }
    mutating func readUInt32() throws -> UInt32 { try readInteger() }
    mutating func readUInt64() throws -> UInt64 { try readInteger() }
    mutating func readFloat() throws -> Float { Float(bitPattern: try readUInt32()) }

    mutating func readBool() throws -> Bool {
        switch try readUInt8() {
        case 0: return false
        case 1: return true
        case let other: throw RemoteCoreError.invalidValue("bool \(other)")
        }
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, remainingCount >= count else { throw RemoteCoreError.truncatedData }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readRemaining() -> Data {
        defer { offset = data.count }
        return data.subdata(in: offset..<data.count)
    }

    /// 読み残しがあればエラーにする。
    func expectEnd() throws {
        guard remainingCount == 0 else { throw RemoteCoreError.trailingData }
    }

    private mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingCount >= size else { throw RemoteCoreError.truncatedData }
        var value: T = 0
        for byte in data[offset..<(offset + size)] {
            value = (value << 8) | T(byte)
        }
        offset += size
        return value
    }
}
