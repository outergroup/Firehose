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

    private var undoHistory = TextUndoHistory()
    private var savedHistories: [String: (String, TextUndoHistory)] = [:]
    private var historyKey: String?

    var markedRange: Range<Int>? { markedTextRange }

    private var undoSelection: TextEditSelection {
        TextEditSelection(caret: stringIndex(forCharacterIndex: cursorPosition).utf16Offset(in: text),
                          anchor: selectionAnchor.map { stringIndex(forCharacterIndex: $0).utf16Offset(in: text) })
    }

    func breakUndoCoalescing() {
        undoHistory.finishComposition(text: text, selection: undoSelection)
        undoHistory.breakCoalescing()
        markedTextRange = nil
        pendingMarkedTextRange = nil
    }

    func resetUndoHistory() {
        undoHistory.reset()
        savedHistories.removeAll()
        historyKey = nil
    }

    func setText(_ newText: String, historyKey key: String) {
        breakUndoCoalescing()
        if let historyKey { savedHistories[historyKey] = (text, undoHistory) }
        let history = savedHistories[key]
        setText(newText)
        undoHistory = history.flatMap { $0.0.utf16.elementsEqual(newText.utf16) ? $0.1 : nil } ?? TextUndoHistory()
        historyKey = key
    }

    func pasteText(_ value: String) {
        guard isFocused else { return }
        breakUndoCoalescing()
        replaceText(range: selectionRange ?? cursorPosition..<cursorPosition, with: value, kind: .paste)
        breakUndoCoalescing()
    }

    private func applyUndo(redo: Bool) {
        breakUndoCoalescing()
        guard let result = redo ? undoHistory.redo(text: text) : undoHistory.undo(text: text) else { return }
        text = result.text
        cursorPosition = characterIndexForUTF16(result.selection.caret)
        selectionAnchor = result.selection.anchor.map { characterIndexForUTF16($0) }
        notifyStateChanged()
    }

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
        breakUndoCoalescing()
        isFocused = false
        selectionAnchor = nil
        markedTextRange = nil
        pendingMarkedTextRange = nil
        notifyStateChanged()
    }

    func setText(_ newText: String) {
        undoHistory = TextUndoHistory()
        historyKey = nil
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
            replaceText(range: replacementRange, with: value)
            return
        }
        switch value {
        case "\u{8}": deleteBackward(); return
        case "\u{7f}": deleteForward(); return
        case "\u{2190}": moveCursorLeft(); return
        case "\u{2192}": moveCursorRight(); return
        case "\n", "\r":
            breakUndoCoalescing(); onSubmit?(); return
        default: break
        }
        let range = markedTextRange ?? pendingMarkedTextRange ?? selectionRange ?? cursorPosition..<cursorPosition
        if value == "\t" { breakUndoCoalescing() }
        replaceText(range: range, with: value, kind: .typing)
        if value == "\t" { breakUndoCoalescing() }
    }

    func setMarkedText(_ markedText: String,
                       selectedLocation: Int,
                       selectedLength: Int,
                       replacementRange: Range<Int>?) {
        guard isFocused else { return }
        undoHistory.beginComposition(text: text, selection: undoSelection)
        let range = normalizedRange(replacementRange)
            ?? markedTextRange
            ?? selectionRange
            ?? cursorPosition..<cursorPosition
        let lower = min(max(range.lowerBound, 0), text.count)
        let newMarkedRange = lower..<(lower + markedText.count)
        markedTextRange = markedText.isEmpty ? nil : newMarkedRange
        pendingMarkedTextRange = nil
        replaceText(range: range, with: markedText, clearsMarkedText: false)

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
        case "undo": applyUndo(redo: false)
        case "redo": applyUndo(redo: true)
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
            breakUndoCoalescing(); onSubmit?()
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
        if requestedCommands.contains(.undo), undoHistory.canUndo || undoHistory.isComposing { enabledCommands.insert(.undo) }
        if requestedCommands.contains(.redo), undoHistory.canRedo && !undoHistory.isComposing { enabledCommands.insert(.redo) }
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

    private func replaceText(range: Range<Int>, with replacement: String, clearsMarkedText: Bool = true, kind: TextUndoHistory.Kind = .replacement) {
        guard isFocused else { return }
        let lower = min(max(range.lowerBound, 0), text.count)
        let upper = min(max(range.upperBound, lower), text.count)
        let startIndex = stringIndex(forCharacterIndex: lower)
        let endIndex = stringIndex(forCharacterIndex: upper)
        let utf16Range = NSRange(startIndex..<endIndex, in: text)
        let removed = String(text[startIndex..<endIndex])
        let before = undoSelection
        let composing = undoHistory.isComposing
        text.replaceSubrange(startIndex..<endIndex, with: replacement)
        cursorPosition = characterIndexForUTF16(utf16Range.location + replacement.utf16.count)
        selectionAnchor = nil
        if clearsMarkedText {
            markedTextRange = nil
            pendingMarkedTextRange = nil
        }
        if composing {
            if clearsMarkedText { undoHistory.finishComposition(text: text, selection: undoSelection) }
        } else {
            undoHistory.record(range: utf16Range, removed: removed, inserted: replacement,
                               before: before, after: undoSelection, kind: kind)
        }
        notifyStateChanged()
    }

    private func deleteBackward() {
        guard isFocused else { return }
        if hasSelection { deleteSelection(); return }
        guard cursorPosition > 0 else { return }
        undoHistory.finishComposition(text: text, selection: undoSelection)
        replaceText(range: (cursorPosition - 1)..<cursorPosition, with: "", kind: .backwardDelete)
    }

    private func deleteForward() {
        guard isFocused else { return }
        if hasSelection { deleteSelection(); return }
        guard cursorPosition < text.count else { return }
        undoHistory.finishComposition(text: text, selection: undoSelection)
        replaceText(range: cursorPosition..<(cursorPosition + 1), with: "", kind: .forwardDelete)
    }

    func cutSelectedTextContent() -> String? {
        guard isFocused, let range = selectionRange, let selected = selectedTextContent() else { return nil }
        breakUndoCoalescing()
        replaceText(range: range, with: "", kind: .cut)
        breakUndoCoalescing()
        return selected
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
        breakUndoCoalescing()
        replaceText(range: range, with: "", kind: .delete)
    }

    private func deleteWordBackward() {
        guard isFocused else { return }
        if hasSelection { deleteSelection(); return }
        guard cursorPosition > 0 else { return }
        undoHistory.finishComposition(text: text, selection: undoSelection)
        replaceText(range: findPreviousWordBoundary(from: cursorPosition)..<cursorPosition, with: "", kind: .delete)
    }

    private func deleteWordForward() {
        guard isFocused else { return }
        if hasSelection { deleteSelection(); return }
        guard cursorPosition < text.count else { return }
        undoHistory.finishComposition(text: text, selection: undoSelection)
        replaceText(range: cursorPosition..<findNextWordBoundary(from: cursorPosition), with: "", kind: .delete)
    }

    private func deleteToBeginning() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition > 0 else { return }
        replaceText(range: 0..<cursorPosition, with: "")
    }

    private func deleteToEnd() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard cursorPosition < text.count else { return }
        replaceText(range: cursorPosition..<text.count, with: "")
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
        breakUndoCoalescing()
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
