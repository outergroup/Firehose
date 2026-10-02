#!/usr/bin/env python3
"""Test the app's production single-line accessibility geometry."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / "Frontend/TraceContent.swift").read_text()
helper = source[source.index("private func accessibilitySingleLineQuery("):]
fixture = r'''
import AppKit
import CoreText
HELPER
let text = "a😀e\u{301}z"
let font = NSFont.systemFont(ofSize: 13)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
let frame = CGRect(x: 17, y: 31, width: 240, height: 18)
func query(_ kind: OuterframeAccessibilityTextQuery, _ range: NSRange = NSRange(location: 0, length: 0), _ point: CGPoint = .zero) -> OuterframeAccessibilityTextResult? {
    accessibilitySingleLineQuery(kind, range: range, point: point, text: text, line: line, frame: frame)
}
precondition(query(.frameForRange, NSRange(location: 2, length: 1)) == nil)
let emoji = query(.frameForRange, NSRange(location: 1, length: 2))!
precondition(emoji.frame.height == 18 && emoji.frame.minY == 31)
precondition(query(.rangeForPosition, NSRange(location: 0, length: 0), CGPoint(x: emoji.frame.maxX - 0.1, y: emoji.frame.midY))?.range == NSRange(location: 1, length: 2))
precondition(query(.rangeForPosition, NSRange(location: 0, length: 0), .zero) == nil)
precondition(query(.rangeForLine)?.range == NSRange(location: 0, length: 6))
precondition(query(.rangeForLine, NSRange(location: 1, length: 0)) == nil)
precondition(query(.visibleRange)?.range.length == 6)
precondition(query(.frameForRange, NSRange(location: 6, length: 0))?.frame.width == 1)
let emptyLine = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: [.font: font]))
precondition(accessibilitySingleLineQuery(.frameForRange, range: NSRange(location: 0, length: 0), point: .zero, text: "", line: emptyLine, frame: frame)?.frame.width == 1)
print("PASS field accessibility geometry: emoji, combining marks, hit testing, invalid ranges, caret, empty field")
'''.replace("HELPER", helper)
with tempfile.TemporaryDirectory(prefix="field-ax-test-") as directory:
    main = Path(directory) / "main.swift"
    binary = Path(directory) / "test"
    main.write_text(fixture)
    subprocess.run(["swiftc", str(root / "Vendor/OuterframeSwiftMethods/OuterframeAccessibility.swift"), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
