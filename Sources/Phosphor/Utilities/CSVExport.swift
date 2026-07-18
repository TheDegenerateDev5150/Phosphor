import Foundation

enum CSVExport {
    /// RFC 4180-style CSV field escaping plus spreadsheet formula neutralization.
    /// Prefixing formula-looking cells keeps exported iOS data from executing if
    /// a user opens the CSV in Numbers, Excel, or Sheets.
    static func field(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        if let first = value.drop(while: { $0 == " " || $0 == "\t" }).first,
           ["=", "+", "-", "@"].contains(String(first)) {
            value = "'" + value
        }

        value = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(value)\""
    }

    static func row(_ fields: [String], lineEnding: String = "\n") -> String {
        fields.map(field).joined(separator: ",") + lineEnding
    }
}
