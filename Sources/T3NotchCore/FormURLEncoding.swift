import Foundation

enum FormURLEncoding {
    private static let hexadecimal = Array("0123456789ABCDEF".utf8)

    static func data(_ fields: [(String, String)]) -> Data {
        let body = fields.map { field in
            "\(encode(field.0))=\(encode(field.1))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func encode(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if byte == 0x20 {
                encoded.append("+")
            } else if isFormUnescaped(byte) {
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                encoded.append("%")
                encoded.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte >> 4)]))
                encoded.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte & 0x0F)]))
            }
        }
        return encoded
    }

    private static func isFormUnescaped(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || (byte >= 48 && byte <= 57)
            || byte == 42
            || byte == 45
            || byte == 46
            || byte == 95
    }
}
