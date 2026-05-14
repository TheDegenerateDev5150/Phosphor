import Foundation
import CommonCrypto

/// Extracts and exports iMessage/SMS conversations from iOS backup sms.db.
///
/// The sms.db is stored at HomeDomain/Library/SMS/sms.db in the backup.
/// Its SHA-1 hash in Manifest.db is the famous "3d0d7e5fb2ce288813306e4d4636395e047a3d28".
final class MessageExporter {

    /// The well-known SHA-1 hash for sms.db in iOS backups.
    static let smsDbHash = "3d0d7e5fb2ce288813306e4d4636395e047a3d28"

    private let db: SQLiteReader
    /// Backup root for attachment lookups - nil when initialised from a raw sms.db path.
    private let backupPath: String?

    init(databasePath: String, backupPath: String? = nil) throws {
        self.db = try SQLiteReader(path: databasePath)
        self.backupPath = backupPath
    }

    /// Initialize from a backup directory by locating the sms.db.
    convenience init(backupPath: String) throws {
        // The sms.db file is stored as its SHA-1 hash in a two-character prefixed subdirectory
        let hashPrefix = String(Self.smsDbHash.prefix(2))
        let smsPath = "\(backupPath)/\(hashPrefix)/\(Self.smsDbHash)"

        guard FileManager.default.fileExists(atPath: smsPath) else {
            throw NSError(domain: "Phosphor", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "sms.db not found in backup. Is this an unencrypted backup?"])
        }

        try self.init(databasePath: smsPath, backupPath: backupPath)
    }

    // MARK: - Conversations

    /// Get all chat conversations. Empty / tombstoned chats (no messages) are
    /// hidden because iOS keeps deleted-conversation rows in sms.db that would
    /// otherwise flood the UI - see issue #8.
    func getChats(includeEmpty: Bool = false) throws -> [MessageChat] {
        let havingClause = includeEmpty ? "" : "HAVING msg_count > 0"
        let sql = """
            SELECT
                c.ROWID,
                c.chat_identifier,
                c.display_name,
                c.style,
                (SELECT COUNT(*) FROM chat_message_join cmj WHERE cmj.chat_id = c.ROWID) as msg_count,
                (SELECT MAX(m.date) FROM message m
                 JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                 WHERE cmj.chat_id = c.ROWID) as last_date
            FROM chat c
            GROUP BY c.ROWID
            \(havingClause)
            ORDER BY last_date DESC
        """

        let rows = try db.query(sql)
        return rows.compactMap { row -> MessageChat? in
            guard let rowId = row["ROWID"] as? Int,
                  let chatId = row["chat_identifier"] as? String else { return nil }

            let lastDate: Date?
            if let timestamp = row["last_date"] as? Int {
                lastDate = Message.dateFromAppleTimestamp(timestamp)
            } else {
                lastDate = nil
            }

            return MessageChat(
                id: rowId,
                chatIdentifier: chatId,
                displayName: (row["display_name"] as? String) ?? "",
                lastMessageDate: lastDate,
                messageCount: (row["msg_count"] as? Int) ?? 0,
                isGroupChat: (row["style"] as? Int) == 43
            )
        }
    }

    /// Get all messages in a specific chat.
    func getMessages(chatId: Int) throws -> [Message] {
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.cache_has_attachments,
                m.is_read,
                COALESCE(h.id, '') as handle_id,
                a.filename as attachment_filename,
                a.mime_type as attachment_mime
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE cmj.chat_id = ?
            ORDER BY m.date ASC, m.ROWID ASC
        """

        let rows = try db.query(sql, params: [String(chatId)])
        return rows.compactMap(parseMessage)
    }

    /// Resolve an attachment row's `filename` (e.g. `~/Library/SMS/Attachments/...`)
    /// to the SHA-1 hashed file on disk inside the backup. Returns nil when no backup
    /// path is known or the file does not exist.
    func resolveAttachmentDiskPath(filename: String) -> String? {
        guard let backupPath else { return nil }

        // sms.db stores attachment filenames as device-absolute paths beginning
        // with `~/Library/SMS/Attachments/...`. The backup keeps them under the
        // MediaDomain with relativePath stripped of the leading tilde.
        var relative = filename
        if relative.hasPrefix("~/") { relative.removeFirst(2) }
        if relative.hasPrefix("/var/mobile/") { relative.removeFirst("/var/mobile/".count) }
        if relative.hasPrefix("/private/var/mobile/") { relative.removeFirst("/private/var/mobile/".count) }

        // SHA-1 of "MediaDomain-<relative>" is the on-disk filename.
        let domainKey = "MediaDomain-\(relative)"
        let hash = MessageExporter.sha1Hex(domainKey)
        let candidate = "\(backupPath)/\(String(hash.prefix(2)))/\(hash)"
        if FileManager.default.fileExists(atPath: candidate) { return candidate }
        return nil
    }

    /// SHA-1 implementation used to derive backup filenames. Uses CommonCrypto.
    private static func sha1Hex(_ str: String) -> String {
        let data = Data(str.utf8)
        var digest = [UInt8](repeating: 0, count: Int(20))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Get all messages (across all chats).
    func getAllMessages(limit: Int = 10000) throws -> [Message] {
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.cache_has_attachments,
                m.is_read,
                COALESCE(h.id, '') as handle_id,
                a.filename as attachment_filename,
                a.mime_type as attachment_mime
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql)
        return rows.compactMap(parseMessage)
    }

    /// Search messages by text content.
    func searchMessages(_ query: String, limit: Int = 500) throws -> [Message] {
        let sql = """
            SELECT
                m.ROWID,
                m.guid,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                m.cache_has_attachments,
                m.is_read,
                COALESCE(h.id, '') as handle_id,
                a.filename as attachment_filename,
                a.mime_type as attachment_mime
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            LEFT JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE m.text LIKE ?
            ORDER BY m.date DESC
            LIMIT \(limit)
        """

        let rows = try db.query(sql, params: ["%\(query)%"])
        return rows.compactMap(parseMessage)
    }

    // MARK: - Export

    /// Export messages to a file in the specified format.
    func exportChat(chatId: Int, format: MessageExportFormat, to path: String) throws {
        let messages = try getMessages(chatId: chatId)
        let chats = try getChats(includeEmpty: true)
        let chat = chats.first { $0.id == chatId }
        let chatTitle = chat?.title ?? "Unknown"

        switch format {
        case .csv:
            try exportCSV(messages: messages, chatTitle: chatTitle, to: path)
        case .txt:
            try exportPlainText(messages: messages, chatTitle: chatTitle, to: path)
        case .html:
            try exportHTML(messages: messages, chatTitle: chatTitle, to: path)
        case .json:
            try exportJSON(messages: messages, chatTitle: chatTitle, to: path)
        case .mbox:
            try exportMbox(messages: messages, chatTitle: chatTitle, to: path)
        }
    }

    /// Export all conversations.
    func exportAllChats(format: MessageExportFormat, to directory: String) throws -> Int {
        let chats = try getChats()
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        var count = 0
        for chat in chats {
            let safeName = chat.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(50)
            let filename = "\(safeName).\(format.fileExtension)"
            let path = (directory as NSString).appendingPathComponent(String(filename))
            try exportChat(chatId: chat.id, format: format, to: path)
            count += 1
        }
        return count
    }

    // MARK: - Private Export Implementations

    private func exportCSV(messages: [Message], chatTitle: String, to path: String) throws {
        var csv = "Date,Sender,Text,Service\n"
        for msg in messages {
            let text = (msg.text ?? "")
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
            csv += "\"\(msg.formattedDate)\",\"\(msg.senderLabel)\",\"\(text)\",\"\(msg.service)\"\n"
        }
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func exportPlainText(messages: [Message], chatTitle: String, to path: String) throws {
        var lines = "Conversation: \(chatTitle)\n"
        lines += "Exported by Phosphor\n"
        lines += String(repeating: "-", count: 60) + "\n\n"

        for msg in messages {
            let prefix = msg.isFromMe ? "Me" : msg.handleId
            lines += "[\(msg.formattedDate)] \(prefix):\n"
            lines += "\(msg.displayText)\n\n"
        }
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Copy referenced attachments into a sibling `<export>_attachments` folder so the
    /// HTML can <img>/<a href> them. Returns map of attachment filename -> relative
    /// path used inside the HTML. Failures are silent: attachments missing from the
    /// backup just stay as text annotations.
    private func stageAttachments(messages: [Message], htmlPath: String) -> [String: String] {
        let baseName = (htmlPath as NSString).deletingPathExtension
        let dir = "\(baseName)_attachments"
        let fm = FileManager.default
        var map: [String: String] = [:]
        var folderCreated = false

        for msg in messages {
            guard let filename = msg.attachmentFilename, !filename.isEmpty else { continue }
            if map[filename] != nil { continue }
            guard let source = resolveAttachmentDiskPath(filename: filename) else { continue }

            if !folderCreated {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                folderCreated = true
            }

            let displayName = (filename as NSString).lastPathComponent
            var unique = displayName
            var dest = (dir as NSString).appendingPathComponent(unique)
            var i = 2
            while fm.fileExists(atPath: dest) {
                let ext = (displayName as NSString).pathExtension
                let stem = (displayName as NSString).deletingPathExtension
                unique = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
                dest = (dir as NSString).appendingPathComponent(unique)
                i += 1
            }
            do {
                try fm.copyItem(atPath: source, toPath: dest)
                let folderName = (dir as NSString).lastPathComponent
                map[filename] = "\(folderName)/\(unique)"
            } catch {
                continue
            }
        }
        return map
    }

    private func exportHTML(messages: [Message], chatTitle: String, to path: String) throws {
        let attachmentMap = stageAttachments(messages: messages, htmlPath: path)

        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <title>\(chatTitle) - Phosphor Export</title>
        <style>
            * { margin: 0; padding: 0; box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
                   background: #f5f5f7; padding: 24px; max-width: 680px; margin: 0 auto; }
            h1 { font-size: 22px; font-weight: 600; color: #1d1d1f; margin-bottom: 4px; }
            .meta { font-size: 13px; color: #86868b; margin-bottom: 24px; }
            .bubble { padding: 10px 14px; border-radius: 18px; margin: 3px 0; max-width: 75%;
                      font-size: 15px; line-height: 1.4; word-wrap: break-word; }
            .from-me { background: #007aff; color: white; margin-left: auto; border-bottom-right-radius: 4px; }
            .from-them { background: #e9e9eb; color: #1d1d1f; border-bottom-left-radius: 4px; }
            .msg-row { display: flex; margin: 2px 0; }
            .msg-row.me { justify-content: flex-end; }
            .time { font-size: 11px; color: #86868b; text-align: center; margin: 12px 0 4px; }
            .sender { font-size: 11px; color: #86868b; margin-left: 14px; margin-top: 8px; }
            .attach-img { display: block; max-width: 320px; border-radius: 14px; margin: 3px 0; }
            .attach-link { display: inline-block; padding: 8px 12px; border-radius: 12px;
                           background: #e9e9eb; color: #1d1d1f; font-size: 13px; text-decoration: none; }
            .from-me .attach-link { background: rgba(255,255,255,0.25); color: white; }
        </style>
        </head>
        <body>
        <h1>\(chatTitle)</h1>
        <p class="meta">Exported by Phosphor &middot; \(Date().shortString)</p>
        """

        var lastDateStr = ""
        var lastSender = ""

        for msg in messages {
            let dateStr = msg.formattedDate
            if dateStr != lastDateStr {
                html += "<div class=\"time\">\(dateStr)</div>\n"
                lastDateStr = dateStr
            }

            let sender = msg.isFromMe ? "Me" : msg.handleId
            if sender != lastSender && !msg.isFromMe {
                html += "<div class=\"sender\">\(sender)</div>\n"
                lastSender = sender
            }

            let cssClass = msg.isFromMe ? "me" : ""
            let bubbleClass = msg.isFromMe ? "from-me" : "from-them"
            let rawText = msg.text ?? ""
            let text = rawText
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")

            var bubbleHTML = ""
            if !text.isEmpty {
                bubbleHTML += text
            }
            if let attachFilename = msg.attachmentFilename,
               let relPath = attachmentMap[attachFilename] {
                let mime = msg.attachmentMimeType ?? ""
                let isImage = mime.hasPrefix("image/")
                    || ["png", "jpg", "jpeg", "heic", "gif", "webp"].contains(
                        (relPath as NSString).pathExtension.lowercased()
                    )
                if !bubbleHTML.isEmpty { bubbleHTML += "<br>" }
                if isImage {
                    bubbleHTML += "<img class=\"attach-img\" src=\"\(relPath)\" loading=\"lazy\">"
                } else {
                    let name = (relPath as NSString).lastPathComponent
                    bubbleHTML += "<a class=\"attach-link\" href=\"\(relPath)\">\(name)</a>"
                }
            } else if bubbleHTML.isEmpty && msg.hasAttachment {
                bubbleHTML = "[Attachment]"
            }

            html += "<div class=\"msg-row \(cssClass)\"><div class=\"bubble \(bubbleClass)\">\(bubbleHTML)</div></div>\n"
        }

        html += "</body></html>"
        try html.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Export messages as RFC 4155 mbox (mboxo). Each message becomes a separate
    /// RFC 5322 envelope so Mail.app, Thunderbird, mutt, etc. can import the
    /// conversation as a mail folder. Attachments are embedded as base64 MIME parts
    /// when the backup file is available, otherwise referenced by name only.
    private func exportMbox(messages: [Message], chatTitle: String, to path: String) throws {
        let crlf = "\r\n"
        let userDomain = "phosphor.local"
        var out = ""

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let rfc5322Formatter = DateFormatter()
        rfc5322Formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        rfc5322Formatter.locale = Locale(identifier: "en_US_POSIX")

        for msg in messages {
            let envelopeDate = dateFormatter.string(from: msg.date)
            let envelopeFrom = msg.isFromMe ? "me" : (msg.handleId.isEmpty ? "unknown" : msg.handleId)
            let envelopeAddr = mboxAddress(envelopeFrom, domain: userDomain)

            // mboxo: ">From " escape protects the From-line delimiter.
            out += "From \(envelopeAddr) \(envelopeDate)\(crlf)"

            let fromHeader = msg.isFromMe
                ? "Me <me@\(userDomain)>"
                : "\(headerEncode(msg.handleId)) <\(mboxAddress(msg.handleId, domain: userDomain))>"
            let toHeader = msg.isFromMe
                ? "\(headerEncode(chatTitle)) <\(mboxAddress(chatTitle, domain: userDomain))>"
                : "Me <me@\(userDomain)>"

            out += "From: \(fromHeader)\(crlf)"
            out += "To: \(toHeader)\(crlf)"
            out += "Date: \(rfc5322Formatter.string(from: msg.date))\(crlf)"
            out += "Subject: \(headerEncode(chatTitle))\(crlf)"
            out += "Message-ID: <\(msg.guid)@\(userDomain)>\(crlf)"
            out += "X-Phosphor-Service: \(msg.service)\(crlf)"
            out += "MIME-Version: 1.0\(crlf)"

            let body = msg.text ?? ""
            let attachmentFilename = msg.attachmentFilename
            let attachmentDiskPath = attachmentFilename.flatMap { resolveAttachmentDiskPath(filename: $0) }

            if let attachmentDiskPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: attachmentDiskPath)) {
                let boundary = "----=_Phosphor_\(msg.guid)"
                out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\(crlf)\(crlf)"

                out += "--\(boundary)\(crlf)"
                out += "Content-Type: text/plain; charset=UTF-8\(crlf)"
                out += "Content-Transfer-Encoding: 8bit\(crlf)\(crlf)"
                out += mboxEscape(body.isEmpty ? "[Attachment]" : body) + crlf + crlf

                let name = (attachmentFilename.map { ($0 as NSString).lastPathComponent }) ?? "attachment"
                let mime = msg.attachmentMimeType ?? "application/octet-stream"
                out += "--\(boundary)\(crlf)"
                out += "Content-Type: \(mime); name=\"\(headerEncode(name))\"\(crlf)"
                out += "Content-Disposition: attachment; filename=\"\(headerEncode(name))\"\(crlf)"
                out += "Content-Transfer-Encoding: base64\(crlf)\(crlf)"
                out += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                out += crlf + "--\(boundary)--\(crlf)\(crlf)"
            } else {
                out += "Content-Type: text/plain; charset=UTF-8\(crlf)"
                out += "Content-Transfer-Encoding: 8bit\(crlf)\(crlf)"
                var bodyOut = body
                if let attachmentFilename, bodyOut.isEmpty {
                    bodyOut = "[Attachment: \(attachmentFilename)]"
                } else if let attachmentFilename {
                    bodyOut += "\n\n[Attachment: \(attachmentFilename)]"
                }
                out += mboxEscape(bodyOut) + crlf + crlf
            }
        }

        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Mbox bodies must escape lines that start with `From ` so the delimiter remains unambiguous.
    private func mboxEscape(_ body: String) -> String {
        body.components(separatedBy: "\n").map { line in
            line.hasPrefix("From ") ? ">" + line : line
        }.joined(separator: "\r\n")
    }

    /// Build a safe local-part for synthetic email addresses derived from handle ids.
    private func mboxAddress(_ raw: String, domain: String) -> String {
        let cleaned = raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || "._-+".contains($0) }
        let local = cleaned.isEmpty ? "unknown" : cleaned
        return "\(local)@\(domain)"
    }

    /// RFC 2047 encoded-word for header values containing non-ASCII.
    private func headerEncode(_ raw: String) -> String {
        if raw.allSatisfy({ $0.isASCII }) { return raw }
        let base64 = Data(raw.utf8).base64EncodedString()
        return "=?UTF-8?B?\(base64)?="
    }

    private func exportJSON(messages: [Message], chatTitle: String, to path: String) throws {
        let entries: [[String: Any]] = messages.map { msg in
            [
                "id": msg.id,
                "date": msg.date.iso8601String,
                "sender": msg.senderLabel,
                "text": msg.text ?? "",
                "is_from_me": msg.isFromMe,
                "service": msg.service,
                "has_attachment": msg.hasAttachment
            ]
        }

        let root: [String: Any] = [
            "chat": chatTitle,
            "exported_at": Date().iso8601String,
            "exported_by": "Phosphor",
            "message_count": messages.count,
            "messages": entries
        ]

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Private Helpers

    private func parseMessage(_ row: [String: Any?]) -> Message? {
        guard let rowId = row["ROWID"] as? Int,
              let guid = row["guid"] as? String else { return nil }

        let date: Date
        if let timestamp = row["date"] as? Int {
            date = Message.dateFromAppleTimestamp(timestamp)
        } else {
            date = Date.distantPast
        }

        return Message(
            id: rowId,
            guid: guid,
            text: row["text"] as? String,
            date: date,
            isFromMe: (row["is_from_me"] as? Int) == 1,
            handleId: (row["handle_id"] as? String) ?? "",
            service: (row["service"] as? String) ?? "iMessage",
            hasAttachment: (row["cache_has_attachments"] as? Int) == 1
                || (row["attachment_filename"] as? String) != nil,
            attachmentFilename: row["attachment_filename"] as? String,
            attachmentMimeType: row["attachment_mime"] as? String,
            isRead: (row["is_read"] as? Int) == 1
        )
    }
}
