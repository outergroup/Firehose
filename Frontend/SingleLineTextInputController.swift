import AppKit
import CoreText
import Foundation

@MainActor
protocol SingleLineTextInputControllerDelegate: AnyObject {
    func textInputControllerDidChangeState()
}

@MainActor
final class SingleLineTextInputController<DelegateClass: SingleLineTextInputControllerDelegate> {
    let identifier: UUID
    weak var delegate: DelegateClass?
    var onSubmit: (() -> Void)?

    private(set) var text: String
    private(set) var cursorPosition: Int
    private var selectionAnchor: Int?
    private(set) var isFocused: Bool
    private var markedTextRange: Range<Int>?
    private var pendingMarkedTextRange: Range<Int>?
    private let acceptedPasteboardTypeIdentifiers: [String]

    init(identifier: UUID,
         initialText: String = "",
         acceptedPasteboardTypeIdentifiers: [String] = [NSPasteboard.PasteboardType.string.rawValue]) {
        self.identifier = identifier
        self.text = initialText
        self.cursorPosition = initialText.count
        self.selectionAnchor = nil
        self.isFocused = false
        self.acceptedPasteboardTypeIdentifiers = acceptedPasteboardTypeIdentifiers
    }

    var selectionRange: Range<Int>? {
        guard let anchor = selectionAnchor, anchor != cursorPosition else { return nil }
        return anchor < cursorPosition ? anchor..<cursorPosition : cursorPosition..<anchor
    }

    var hasSelection: Bool {
        selectionRange != nil
    }

    func focus(selectAll: Bool = false) {
        guard !isFocused else {
            if selectAll {
                self.selectAll()
            }
            return
        }
        isFocused = true
        if selectAll {
            selectionAnchor = 0
            cursorPosition = text.count
        } else {
            selectionAnchor = nil
        }
        notifyStateChanged()
    }

    func blur() {
        guard isFocused else { return }
        isFocused = false
        selectionAnchor = nil
        markedTextRange = nil
        pendingMarkedTextRange = nil
        notifyStateChanged()
    }

    func setText(_ newText: String) {
        text = newText
        cursorPosition = min(cursorPosition, text.count)
        selectionAnchor = nil
        markedTextRange = nil
        pendingMarkedTextRange = nil
        notifyStateChanged()
    }

    func insertText(_ value: String, replacementRange: Range<Int>? = nil) {
        guard isFocused else { return }

        if let replacementRange {
            replace(range: replacementRange, with: value, clearsMarkedText: true)
            return
        }

        if value == "\u{8}" {
            deleteBackward()
            return
        } else if value == "\u{7f}" {
            deleteForward()
            return
        } else if value == "\u{2190}" {
            moveCursorLeft()
            return
        } else if value == "\u{2192}" {
            moveCursorRight()
            return
        } else if value == "\n" || value == "\r" {
            onSubmit?()
            return
        }

        if let range = markedTextRange ?? pendingMarkedTextRange {
            replace(range: range, with: value, clearsMarkedText: true)
            return
        }

        if hasSelection {
            deleteSelection()
        }

        let index = stringIndex(forCharacterIndex: cursorPosition)
        text.insert(contentsOf: value, at: index)
        cursorPosition += value.count
        selectionAnchor = nil
        markedTextRange = nil
        pendingMarkedTextRange = nil
        notifyStateChanged()
    }

    func setMarkedText(_ markedText: String,
                       selectedLocation: Int,
                       selectedLength: Int,
                       replacementRange: Range<Int>?) {
        guard isFocused else { return }
        let range = normalizedRange(replacementRange)
            ?? markedTextRange
            ?? selectionRange
            ?? cursorPosition..<cursorPosition
        let lower = min(max(range.lowerBound, 0), text.count)
        let newMarkedRange = lower..<(lower + markedText.count)
        markedTextRange = markedText.isEmpty ? nil : newMarkedRange
        pendingMarkedTextRange = nil
        replace(range: range, with: markedText, clearsMarkedText: false)

        let selectedLower = min(max(selectedLocation, 0), markedText.count)
        let selectedUpper = min(max(selectedLower + selectedLength, selectedLower), markedText.count)
        if selectedUpper > selectedLower {
            selectionAnchor = lower + selectedLower
            cursorPosition = lower + selectedUpper
        } else {
            selectionAnchor = nil
            cursorPosition = lower + selectedLower
        }
        notifyStateChanged()
    }

    func unmarkText() {
        guard isFocused else { return }
        pendingMarkedTextRange = markedTextRange
        markedTextRange = nil
        notifyStateChanged()
    }

    func performCommand(_ command: String) {
        guard isFocused else { return }

        switch command.removingSuffix(":") {
        case "moveLeft":
            moveCursorLeft()
        case "moveRight":
            moveCursorRight()
        case "moveUp":
            moveToBeginning()
        case "moveDown":
            moveToEnd()
        case "moveWordLeft":
            moveWordLeft()
        case "moveWordRight":
            moveWordRight()
        case "moveToBeginningOfLine", "moveToBeginningOfDocument", "moveToBeginningOfParagraph", "moveToLeftEndOfLine":
            moveToBeginning()
        case "moveToEndOfLine", "moveToEndOfDocument", "moveToEndOfParagraph", "moveToRightEndOfLine":
            moveToEnd()
        case "moveLeftAndModifySelection":
            moveLeftAndModifySelection()
        case "moveRightAndModifySelection":
            moveRightAndModifySelection()
        case "moveWordLeftAndModifySelection":
            moveWordLeftAndModifySelection()
        case "moveWordRightAndModifySelection":
            moveWordRightAndModifySelection()
        case "moveToBeginningOfLineAndModifySelection", "moveToBeginningOfDocumentAndModifySelection", "moveToBeginningOfParagraphAndModifySelection", "moveToLeftEndOfLineAndModifySelection":
            moveToBeginningAndModifySelection()
        case "moveToEndOfLineAndModifySelection", "moveToEndOfDocumentAndModifySelection", "moveToEndOfParagraphAndModifySelection", "moveToRightEndOfLineAndModifySelection":
            moveToEndAndModifySelection()
        case "selectAll":
            selectAll()
        case "deleteBackward":
            deleteBackward()
        case "deleteForward":
            deleteForward()
        case "deleteWordBackward":
            deleteWordBackward()
        case "deleteWordForward":
            deleteWordForward()
        case "deleteToBeginningOfLine", "deleteToBeginningOfParagraph", "deleteToMark":
            deleteToBeginning()
        case "deleteToEndOfLine", "deleteToEndOfParagraph":
            deleteToEnd()
        case "insertNewline":
            onSubmit?()
        default:
            break
        }
    }

    func setCursorPosition(_ position: Int, modifySelection: Bool) {
        guard isFocused else { return }
        clearMarkedTextState()
        let clamped = clamp(position)
        if modifySelection {
            extendSelection(to: clamped)
        } else {
            cursorPosition = clamped
            selectionAnchor = nil
            notifyStateChanged()
        }
    }

    func selectAll() {
        guard isFocused else { return }
        clearMarkedTextState()
        selectionAnchor = 0
        cursorPosition = text.count
        notifyStateChanged()
    }

    func selectWord(at position: Int) {
        guard isFocused else { return }
        clearMarkedTextState()
        let clamped = clamp(position)
        selectionAnchor = findPreviousWordBoundary(from: clamped)
        cursorPosition = findNextWordBoundary(from: clamped)
        notifyStateChanged()
    }

    func selectedTextContent() -> String? {
        guard let range = selectionRange else { return nil }
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        if lower == upper { return nil }
        return String(text[lower..<upper])
    }

    func enabledEditCommands(in requestedCommands: OuterframeEditCommandSet) -> OuterframeEditCommandSet {
        guard isFocused else { return [] }

        var enabledCommands: OuterframeEditCommandSet = []
        if hasSelection {
            if requestedCommands.contains(.copy) {
                enabledCommands.insert(.copy)
            }
            if requestedCommands.contains(.cut) {
                enabledCommands.insert(.cut)
            }
        }
        if requestedCommands.contains(.paste) {
            enabledCommands.insert(.paste)
        }
        if requestedCommands.contains(.selectAll), !text.isEmpty {
            enabledCommands.insert(.selectAll)
        }
        return enabledCommands
    }

    func currentAcceptedPasteboardTypeIdentifiers() -> [String] {
        isFocused ? acceptedPasteboardTypeIdentifiers : []
    }

    private func replace(range: Range<Int>, with value: String, clearsMarkedText: Bool = true) {
        let clampedRange = clamp(range.lowerBound)..<clamp(range.upperBound)
        let lower = stringIndex(forCharacterIndex: clampedRange.lowerBound)
        let upper = stringIndex(forCharacterIndex: clampedRange.upperBound)
        text.replaceSubrange(lower..<upper, with: value)
        cursorPosition = clampedRange.lowerBound + value.count
        selectionAnchor = nil
        if clearsMarkedText {
            markedTextRange = nil
            pendingMarkedTextRange = nil
        }
        notifyStateChanged()
    }

    private func deleteBackward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition > 0 else { return }
        clearMarkedTextState()
        let removeIndex = text.index(text.startIndex, offsetBy: cursorPosition - 1)
        text.remove(at: removeIndex)
        cursorPosition -= 1
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func deleteForward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition < text.count else { return }
        clearMarkedTextState()
        let removeIndex = stringIndex(forCharacterIndex: cursorPosition)
        text.remove(at: removeIndex)
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveCursorLeft() {
        clearMarkedTextState()
        if let selectionRange {
            cursorPosition = selectionRange.lowerBound
            selectionAnchor = nil
            notifyStateChanged()
            return
        }
        guard cursorPosition > 0 else { return }
        cursorPosition -= 1
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveCursorRight() {
        clearMarkedTextState()
        if let selectionRange {
            cursorPosition = selectionRange.upperBound
            selectionAnchor = nil
            notifyStateChanged()
            return
        }
        guard cursorPosition < text.count else { return }
        cursorPosition += 1
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveToBeginning() {
        clearMarkedTextState()
        cursorPosition = 0
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveToEnd() {
        clearMarkedTextState()
        cursorPosition = text.count
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveWordLeft() {
        clearMarkedTextState()
        if let selectionRange {
            cursorPosition = selectionRange.lowerBound
            selectionAnchor = nil
            notifyStateChanged()
            return
        }
        cursorPosition = findPreviousWordBoundary(from: cursorPosition)
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveWordRight() {
        clearMarkedTextState()
        if let selectionRange {
            cursorPosition = selectionRange.upperBound
            selectionAnchor = nil
            notifyStateChanged()
            return
        }
        cursorPosition = findNextWordBoundary(from: cursorPosition)
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func moveLeftAndModifySelection() {
        clearMarkedTextState()
        extendSelection(to: max(0, cursorPosition - 1))
    }

    private func moveRightAndModifySelection() {
        clearMarkedTextState()
        extendSelection(to: min(text.count, cursorPosition + 1))
    }

    private func moveWordLeftAndModifySelection() {
        clearMarkedTextState()
        extendSelection(to: findPreviousWordBoundary(from: cursorPosition))
    }

    private func moveWordRightAndModifySelection() {
        clearMarkedTextState()
        extendSelection(to: findNextWordBoundary(from: cursorPosition))
    }

    private func moveToBeginningAndModifySelection() {
        clearMarkedTextState()
        extendSelection(to: 0)
    }

    private func moveToEndAndModifySelection() {
        clearMarkedTextState()
        extendSelection(to: text.count)
    }

    private func deleteSelection() {
        guard let range = selectionRange else { return }
        clearMarkedTextState()
        let lower = stringIndex(forCharacterIndex: range.lowerBound)
        let upper = stringIndex(forCharacterIndex: range.upperBound)
        text.removeSubrange(lower..<upper)
        cursorPosition = range.lowerBound
        selectionAnchor = nil
        notifyStateChanged()
    }

    private func deleteWordBackward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition > 0 else { return }
        let boundary = findPreviousWordBoundary(from: cursorPosition)
        replace(range: boundary..<cursorPosition, with: "")
    }

    private func deleteWordForward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition < text.count else { return }
        let boundary = findNextWordBoundary(from: cursorPosition)
        replace(range: cursorPosition..<boundary, with: "")
    }

    private func deleteToBeginning() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition > 0 else { return }
        replace(range: 0..<cursorPosition, with: "")
    }

    private func deleteToEnd() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition < text.count else { return }
        replace(range: cursorPosition..<text.count, with: "")
    }

    private func extendSelection(to position: Int) {
        let clamped = clamp(position)
        if selectionAnchor == nil {
            selectionAnchor = cursorPosition
        }
        cursorPosition = clamped
        notifyStateChanged()
    }

    private func clamp(_ value: Int) -> Int {
        min(max(0, value), text.count)
    }

    private func findPreviousWordBoundary(from position: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let clamped = clamp(position)
        if clamped == 0 { return 0 }

        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault,
                                                text as CFString,
                                                CFRangeMake(0, text.utf16.count),
                                                kCFStringTokenizerUnitWordBoundary,
                                                nil)
        var previousBoundary = 0
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let tokenEnd = range.location + range.length
            let characterIndex = characterIndexForUTF16(tokenEnd)
            if characterIndex >= clamped {
                break
            }
            previousBoundary = characterIndex
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return previousBoundary
    }

    private func findNextWordBoundary(from position: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let clamped = clamp(position)
        if clamped >= text.count { return text.count }

        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault,
                                                text as CFString,
                                                CFRangeMake(0, text.utf16.count),
                                                kCFStringTokenizerUnitWordBoundary,
                                                nil)
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let characterIndex = characterIndexForUTF16(range.location + range.length)
            if characterIndex > clamped {
                return characterIndex
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return text.count
    }

    private func stringIndex(forCharacterIndex index: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: index)
    }

    private func normalizedRange(_ range: Range<Int>?) -> Range<Int>? {
        guard let range else { return nil }
        let lower = min(max(range.lowerBound, 0), text.count)
        let upper = min(max(range.upperBound, lower), text.count)
        return lower..<upper
    }

    private func clearMarkedTextState() {
        markedTextRange = nil
        pendingMarkedTextRange = nil
    }

    private func characterIndexForUTF16(_ utf16Index: Int) -> Int {
        let offset = max(0, min(utf16Index, text.utf16.count))
        let stringIndex = String.Index(utf16Offset: offset, in: text)
        return text.distance(from: text.startIndex, to: stringIndex)
    }

    private func notifyStateChanged() {
        delegate?.textInputControllerDidChangeState()
    }
}

private extension String {
    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
