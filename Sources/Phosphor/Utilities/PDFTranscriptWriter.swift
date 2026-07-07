import AppKit
import CoreText
import Foundation

/// Writes paginated, iMessage-inspired transcript PDFs without loading a WebView
/// or holding a giant rendered document in memory. Messages are drawn as rounded
/// chat bubbles: outgoing messages are right-aligned blue bubbles and incoming
/// messages are left-aligned light-gray bubbles. iMessage metadata that Phosphor
/// extracts (tapbacks, rich links, attachments, service/read status) is rendered
/// as visible transcript affordances instead of being flattened into plain text.
enum PDFTranscriptWriter {
    struct Entry {
        let title: String
        let subtitle: String
        let body: String
        let isFromMe: Bool
        var reactions: [String] = []
        var attachments: [String] = []
        var linkURL: String? = nil
        var status: String? = nil
    }

    static func write(
        title: String,
        subtitle: String,
        entries: [Entry],
        to path: String,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        let outputURL = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: outputURL)

        guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF output file"])
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, 72 DPI
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "Phosphor", code: 500, userInfo: [NSLocalizedDescriptionKey: "Could not create PDF context"])
        }

        let margin: CGFloat = 42
        let contentWidth = mediaBox.width - (margin * 2)
        let pageHeight = mediaBox.height
        let pageBottom = pageHeight - margin
        let bubbleMaxWidth = contentWidth * 0.74
        let bubblePaddingX: CGFloat = 13
        let bubblePaddingY: CGFloat = 9
        let bubbleRadius: CGFloat = 17
        let featureSpacing: CGFloat = 6
        var y: CGFloat = margin
        var pageNumber = 0

        func beginPage() {
            context.beginPDFPage(nil)
            pageNumber += 1
            y = margin
            context.setFillColor(pageBackgroundColor)
            context.fill(mediaBox)
        }

        func endPage() {
            let footer = attributed("Page \(pageNumber)", font: .systemFont(ofSize: 9), color: secondaryTextColor, alignment: .center)
            draw(footer, in: CGRect(x: margin, y: pageHeight - margin + 18, width: contentWidth, height: 14), context: context, pageHeight: pageHeight)
            context.endPDFPage()
        }

        func ensureSpace(_ height: CGFloat) {
            if y + height > pageBottom {
                endPage()
                beginPage()
            }
        }

        func drawHeader() {
            let titleText = attributed(title, font: .systemFont(ofSize: 21, weight: .semibold), color: primaryTextColor, alignment: .center)
            let titleHeight = measuredHeight(titleText, width: contentWidth)
            draw(titleText, in: CGRect(x: margin, y: y, width: contentWidth, height: titleHeight), context: context, pageHeight: pageHeight)
            y += titleHeight + 4

            let metaText = attributed(subtitle, font: .systemFont(ofSize: 10), color: secondaryTextColor, alignment: .center)
            let metaHeight = measuredHeight(metaText, width: contentWidth)
            draw(metaText, in: CGRect(x: margin, y: y, width: contentWidth, height: metaHeight), context: context, pageHeight: pageHeight)
            y += metaHeight + 18
        }

        func drawRoundedRect(x: CGFloat, topY: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, fill: CGColor) {
            let rect = CGRect(x: x, y: pageHeight - topY - height, width: width, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }

        func drawTextSegment(_ text: NSAttributedString,
                             bubbleX: CGFloat,
                             bubbleTopY: CGFloat,
                             textWidth: CGFloat,
                             textHeight: CGFloat,
                             bubbleFill: CGColor) -> Int {
            let bubbleHeight = textHeight + (bubblePaddingY * 2)
            let bubbleWidth = textWidth + (bubblePaddingX * 2)
            drawRoundedRect(x: bubbleX, topY: bubbleTopY, width: bubbleWidth, height: bubbleHeight, radius: bubbleRadius, fill: bubbleFill)
            return draw(
                text,
                in: CGRect(x: bubbleX + bubblePaddingX, y: bubbleTopY + bubblePaddingY, width: textWidth, height: textHeight),
                context: context,
                pageHeight: pageHeight
            )
        }

        func featureText(_ raw: String, isFromMe: Bool) -> NSAttributedString {
            attributed(raw, font: .systemFont(ofSize: 9.5), color: isFromMe ? outgoingTextColor : primaryTextColor)
        }

        func drawFeaturePill(_ raw: String, x: CGFloat, topY: CGFloat, width: CGFloat, isFromMe: Bool) -> CGFloat {
            let text = featureText(raw, isFromMe: isFromMe)
            let height = measuredHeight(text, width: width - 18) + 8
            drawRoundedRect(
                x: x,
                topY: topY,
                width: width,
                height: height,
                radius: 10,
                fill: isFromMe ? outgoingFeatureColor : incomingFeatureColor
            )
            draw(text, in: CGRect(x: x + 9, y: topY + 4, width: width - 18, height: height - 8), context: context, pageHeight: pageHeight)
            return height
        }

        func drawReactionBadge(_ entry: Entry, bubbleX: CGFloat, bubbleTopY: CGFloat, bubbleWidth: CGFloat) {
            guard !entry.reactions.isEmpty else { return }
            let badgeText = attributed(entry.reactions.joined(separator: "  "), font: .systemFont(ofSize: 10, weight: .medium), color: primaryTextColor)
            let badgeTextWidth = min(180, max(24, measuredSize(badgeText, width: 180).width))
            let badgeWidth = badgeTextWidth + 14
            let badgeHeight: CGFloat = 20
            let badgeX = entry.isFromMe ? max(margin, bubbleX - badgeWidth + 12) : min(margin + contentWidth - badgeWidth, bubbleX + bubbleWidth - 12)
            let badgeY = max(margin + 2, bubbleTopY - 10)
            drawRoundedRect(x: badgeX, topY: badgeY, width: badgeWidth, height: badgeHeight, radius: 10, fill: reactionBadgeColor)
            context.setStrokeColor(reactionBadgeBorderColor)
            context.setLineWidth(0.5)
            let rect = CGRect(x: badgeX, y: pageHeight - badgeY - badgeHeight, width: badgeWidth, height: badgeHeight)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
            draw(badgeText, in: CGRect(x: badgeX + 7, y: badgeY + 3, width: badgeTextWidth, height: badgeHeight - 6), context: context, pageHeight: pageHeight)
        }

        func drawMessageFeatures(_ entry: Entry, bubbleX: CGFloat, textWidth: CGFloat) {
            var features: [String] = []
            if !entry.reactions.isEmpty { features.append("Tapbacks: \(entry.reactions.joined(separator: ", "))") }
            if let link = entry.linkURL, !link.isEmpty { features.append("🔗 \(link)") }
            features.append(contentsOf: entry.attachments.map { "📎 \($0)" })
            if let status = entry.status, !status.isEmpty { features.append("ℹ︎ \(status)") }

            guard !features.isEmpty else { return }
            let bubbleWidth = textWidth + (bubblePaddingX * 2)
            for feature in features {
                ensureSpace(26)
                let height = drawFeaturePill(feature, x: bubbleX + bubblePaddingX, topY: y, width: textWidth, isFromMe: entry.isFromMe)
                y += height + featureSpacing
            }
            // Keep feature pills visually inside the parent bubble column by adding
            // a small final spacer that mirrors Messages' stacked attachment cards.
            _ = bubbleWidth
        }

        func drawMessage(_ entry: Entry) throws {
            let bubbleFill = entry.isFromMe ? outgoingBubbleColor : incomingBubbleColor
            let textColor = entry.isFromMe ? outgoingTextColor : primaryTextColor
            let text = attributed(entry.body.isEmpty ? "[Empty message]" : entry.body,
                                  font: .systemFont(ofSize: 11.5),
                                  color: textColor)
            let meta = attributed(entry.subtitle,
                                  font: .systemFont(ofSize: 8.5),
                                  color: secondaryTextColor,
                                  alignment: .center)
            let sender = attributed(entry.title,
                                    font: .systemFont(ofSize: 9, weight: .medium),
                                    color: secondaryTextColor)

            let maxTextWidth = bubbleMaxWidth - (bubblePaddingX * 2)
            let preferredTextSize = measuredSize(text, width: maxTextWidth)
            let textWidth = min(maxTextWidth, max(80, ceil(preferredTextSize.width)))
            let metaHeight = entry.subtitle.isEmpty ? CGFloat(0) : measuredHeight(meta, width: contentWidth)
            ensureSpace(max(28, metaHeight + 24))

            if !entry.subtitle.isEmpty {
                draw(meta, in: CGRect(x: margin, y: y, width: contentWidth, height: metaHeight), context: context, pageHeight: pageHeight)
                y += metaHeight + 7
            }

            if !entry.isFromMe, !entry.title.isEmpty {
                let senderHeight = measuredHeight(sender, width: bubbleMaxWidth)
                ensureSpace(senderHeight + 18)
                draw(sender, in: CGRect(x: margin + 6, y: y, width: bubbleMaxWidth, height: senderHeight), context: context, pageHeight: pageHeight)
                y += senderHeight + 2
            }

            var offset = 0
            var lastBubbleX: CGFloat = entry.isFromMe ? margin + contentWidth - (textWidth + bubblePaddingX * 2) : margin
            var didDrawPrimaryBubble = false
            while offset < text.length {
                try cancellationCheck?()
                let remaining = text.attributedSubstring(from: NSRange(location: offset, length: text.length - offset))
                let remainingHeight = measuredHeight(remaining, width: textWidth)

                var availableTextHeight = pageBottom - y - (bubblePaddingY * 2)
                if availableTextHeight < 24 {
                    endPage()
                    beginPage()
                    availableTextHeight = pageBottom - y - (bubblePaddingY * 2)
                }

                let segmentTextHeight = min(remainingHeight, availableTextHeight)
                let bubbleHeight = segmentTextHeight + (bubblePaddingY * 2)
                let bubbleWidth = textWidth + (bubblePaddingX * 2)
                let bubbleX = entry.isFromMe ? margin + contentWidth - bubbleWidth : margin
                let bubbleTopY = y
                lastBubbleX = bubbleX

                let visible = drawTextSegment(
                    remaining,
                    bubbleX: bubbleX,
                    bubbleTopY: bubbleTopY,
                    textWidth: textWidth,
                    textHeight: segmentTextHeight,
                    bubbleFill: bubbleFill
                )
                if !didDrawPrimaryBubble {
                    drawReactionBadge(entry, bubbleX: bubbleX, bubbleTopY: bubbleTopY, bubbleWidth: bubbleWidth)
                    didDrawPrimaryBubble = true
                }

                y += bubbleHeight + 6
                if visible <= 0 { break }
                offset += visible
                if offset < text.length {
                    endPage()
                    beginPage()
                }
            }

            drawMessageFeatures(entry, bubbleX: lastBubbleX, textWidth: textWidth)
            y += 6
        }

        beginPage()
        drawHeader()

        for entry in entries {
            try cancellationCheck?()
            try drawMessage(entry)
        }

        endPage()
        context.closePDF()
    }

    private static let pageBackgroundColor = NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.976, alpha: 1).cgColor
    private static let primaryTextColor = NSColor(calibratedWhite: 0.08, alpha: 1)
    private static let secondaryTextColor = NSColor(calibratedWhite: 0.48, alpha: 1)
    private static let outgoingTextColor = NSColor.white
    private static let outgoingBubbleColor = NSColor(calibratedRed: 0.00, green: 0.478, blue: 1.00, alpha: 1).cgColor
    private static let incomingBubbleColor = NSColor(calibratedRed: 0.898, green: 0.898, blue: 0.918, alpha: 1).cgColor
    private static let outgoingFeatureColor = NSColor(calibratedRed: 0.00, green: 0.39, blue: 0.92, alpha: 0.92).cgColor
    private static let incomingFeatureColor = NSColor(calibratedWhite: 1, alpha: 0.82).cgColor
    private static let reactionBadgeColor = NSColor.white.cgColor
    private static let reactionBadgeBorderColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor

    private static func attributed(_ raw: String,
                                   font: NSFont,
                                   color: NSColor,
                                   alignment: NSTextAlignment = .left) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        paragraph.alignment = alignment
        return NSAttributedString(
            string: raw,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func measuredSize(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: text.length),
            nil,
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            nil
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height) + 2)
    }

    private static func measuredHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        max(measuredSize(text, width: width).height, 12)
    }

    @discardableResult
    private static func draw(_ text: NSAttributedString, in topLeftRect: CGRect, context: CGContext, pageHeight: CGFloat) -> Int {
        context.saveGState()
        let rect = CGRect(
            x: topLeftRect.origin.x,
            y: pageHeight - topLeftRect.origin.y - topLeftRect.height,
            width: topLeftRect.width,
            height: topLeftRect.height
        )
        let path = CGPath(rect: rect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: text.length), path, nil)
        CTFrameDraw(frame, context)
        let visible = CTFrameGetVisibleStringRange(frame).length
        context.restoreGState()
        return visible
    }
}
