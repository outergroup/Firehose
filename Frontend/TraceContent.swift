import AppKit
import CoreText
import Foundation
import QuartzCore

private func makeSystemSymbolImage(systemSymbolName: String,
                                   pointSize: CGFloat,
                                   weight: NSFont.Weight,
                                   scale: CGFloat,
                                   tintColor: NSColor,
                                   appearance: NSAppearance) -> CGImage? {
    guard let image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil) else {
        return nil
    }

    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: tintColor))
    guard let configuredImage = image.withSymbolConfiguration(config) else {
        return nil
    }

    let imageSize = configuredImage.size
    let renderScale = max(scale, 1)
    let pixelWidth = max(Int(ceil(imageSize.width * renderScale)), 1)
    let pixelHeight = max(Int(ceil(imageSize.height * renderScale)), 1)
    let bytesPerRow = pixelWidth * 4
    var data = Data(count: bytesPerRow * pixelHeight)

    return data.withUnsafeMutableBytes { bytes -> CGImage? in
        guard let baseAddress = bytes.baseAddress,
              let context = CGContext(data: baseAddress,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        var outputImage: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSColor.clear.set()
            NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
            context.scaleBy(x: renderScale, y: renderScale)
            configuredImage.draw(in: NSRect(origin: .zero, size: imageSize),
                                 from: .zero,
                                 operation: .sourceOver,
                                 fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            outputImage = context.makeImage()
        }
        return outputImage
    }
}

@MainActor
@objc public final class TraceContent: NSObject, OuterframeContentLibrary {
    @objc public static func start(
        socketFD: Int32,
        appConnection: OuterframeAppConnection
    ) -> Int32 {
        let outerframeHost = OuterframeHost(socketFD: socketFD)
        let handler = TraceHandler(outerframeHost: outerframeHost, appConnection: appConnection)
        outerframeHost.delegate = handler
        return 0
    }
}

private enum TraceEventDecodeError: Error {
    case invalidFormat
}

private struct TraceEventResponse {
    let total: Int
    let unfilteredTotal: Int
    let start: Int
    let count: Int
    let events: [TraceEvent]
}

private struct TraceEvent {
    let id: UInt64
    let timestamp: Double
    let time: String
    let type: String
    let pid: Int
    let ppid: Int
    let process: String
    let path: String
    let detail: String
}

private enum FilterColumn: String, CaseIterable {
    case time
    case event
    case pid
    case ppid
    case process
    case path
    case detail

    var title: String {
        switch self {
        case .time: return "Time"
        case .event: return "Event"
        case .pid: return "PID"
        case .ppid: return "PPID"
        case .process: return "Process"
        case .path: return "Path"
        case .detail: return "Detail"
        }
    }
}

private enum FilterOperation: String, CaseIterable {
    case contains
    case excludes
    case equals
    case notEquals

    var title: String {
        switch self {
        case .contains: return "Contains"
        case .excludes: return "Excludes"
        case .equals: return "Equals"
        case .notEquals: return "Not equals"
        }
    }
}

private struct FilterClause {
    var column: FilterColumn
    var operation: FilterOperation
    var value: String
}

private struct CellFilterContext {
    let menuID: UUID
    let column: FilterColumn
    let value: String
}

private extension Data {
    func traceUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw TraceEventDecodeError.invalidFormat }
        return UInt16(self[offset]) |
               (UInt16(self[offset + 1]) << 8)
    }

    func traceUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw TraceEventDecodeError.invalidFormat }
        return UInt32(self[offset]) |
               (UInt32(self[offset + 1]) << 8) |
               (UInt32(self[offset + 2]) << 16) |
               (UInt32(self[offset + 3]) << 24)
    }

    func traceUInt64(at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { throw TraceEventDecodeError.invalidFormat }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    func traceInt32(at offset: Int) throws -> Int32 {
        Int32(bitPattern: try traceUInt32(at: offset))
    }

    func traceDouble(at offset: Int) throws -> Double {
        Double(bitPattern: try traceUInt64(at: offset))
    }

    func traceStringRef32(at offset: Int) throws -> String {
        let stringOffset = Int(try traceUInt32(at: offset))
        let stringLength = Int(try traceUInt32(at: offset + 4))
        guard stringOffset >= 0,
              stringLength >= 0,
              stringOffset <= count,
              stringLength <= count - stringOffset else {
            throw TraceEventDecodeError.invalidFormat
        }
        let range = stringOffset..<(stringOffset + stringLength)
        guard let string = String(data: subdata(in: range), encoding: .utf8) else {
            throw TraceEventDecodeError.invalidFormat
        }
        return string
    }
}

private func decodeTraceEventResponse(_ data: Data) throws -> TraceEventResponse {
    let magic = try data.traceUInt32(at: 0)
    let version = try data.traceUInt16(at: 4)
    let headerSize = Int(try data.traceUInt16(at: 6))
    let total = try data.traceUInt64(at: 8)
    let start = try data.traceUInt64(at: 16)
    let eventCount = Int(try data.traceUInt32(at: 24))
    let recordSize = Int(try data.traceUInt32(at: 28))

    let unfilteredTotal = headerSize >= 40 ? try data.traceUInt64(at: 32) : total

    guard magic == 0x4543_5254,
          version == 1 || version == 2 || version == 3,
          headerSize >= 32,
          recordSize >= 56,
          total <= UInt64(Int.max),
          unfilteredTotal <= UInt64(Int.max),
          start <= UInt64(Int.max),
          headerSize <= data.count,
          eventCount <= (data.count - headerSize) / recordSize else {
        throw TraceEventDecodeError.invalidFormat
    }

    var events: [TraceEvent] = []
    events.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        let offset = headerSize + index * recordSize
        let pid = Int(try data.traceInt32(at: offset + 16))
        let ppid = Int(try data.traceInt32(at: offset + 20))
        events.append(TraceEvent(id: try data.traceUInt64(at: offset + 0),
                                 timestamp: try data.traceDouble(at: offset + 8),
                                 time: try data.traceStringRef32(at: offset + 24),
                                 type: try data.traceStringRef32(at: offset + 32),
                                 pid: pid,
                                 ppid: ppid,
                                 process: try data.traceStringRef32(at: offset + 40),
                                 path: recordSize >= 64 ? try data.traceStringRef32(at: offset + 56) : "",
                                 detail: try data.traceStringRef32(at: offset + 48)))
    }

    return TraceEventResponse(total: Int(total),
                              unfilteredTotal: Int(unfilteredTotal),
                              start: Int(start),
                              count: eventCount,
                              events: events)
}

@MainActor
private final class TraceHandler: NSObject, OuterframeHostDelegate, SingleLineTextInputControllerDelegate {
    private static let filterFieldID = UUID(uuidString: "E626575E-5EF3-4B83-B394-942B0EA50814")!

    private struct RowLayers {
        let container: CALayer
        let background: CALayer
        let time: CATextLayer
        let type: CATextLayer
        let pid: CATextLayer
        let process: CATextLayer
        let path: CATextLayer
        let detail: CATextLayer
    }

    private let outerframeHost: OuterframeHost
    private let appConnection: OuterframeAppConnection
    private var retainedSelf: TraceHandler?
    private lazy var filterInputController: SingleLineTextInputController<TraceHandler> = {
        let controller = SingleLineTextInputController<TraceHandler>(identifier: Self.filterFieldID)
        controller.delegate = self
        controller.onSubmit = { [weak self] in
            self?.applyFilterChange()
        }
        return controller
    }()

    private var appearance: NSAppearance?
    private let rootLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let statusLayer = CATextLayer()
    private let toolbarLayer = CALayer()
    private let pauseButtonLayer = CALayer()
    private let pauseButtonIconLayer = CALayer()
    private let headerLayer = CALayer()
    private let headerBorderLayer = CALayer()
    private let tableLayer = CALayer()
    private let rowsClipLayer = CALayer()
    private let scrollbarTrackLayer = CALayer()
    private let scrollbarThumbLayer = CALayer()
    private let filterPillLayer = CALayer()
    private let filterPillTextLayer = CATextLayer()
    private let filterPanelLayer = CALayer()
    private var filterRowLayers: [CALayer] = []
    private var filterColumnLayers: [CATextLayer] = []
    private var filterOperationLayers: [CATextLayer] = []
    private var filterValueLayers: [CATextLayer] = []
    private var filterRemoveLayers: [CATextLayer] = []
    private let filterSelectionLayer = CALayer()
    private let filterAddLayer = CATextLayer()
    private var headerTextLayers: [CATextLayer] = []
    private var headerSeparatorLayers: [CALayer] = []
    private var rowLayers: [RowLayers] = []

    private var didRegisterLayer = false
    private var currentSize = CGSize(width: 960, height: 640)
    private var apiEndpoint: URL?
    private var captureEndpoint: URL?
    private var urlSession: URLSession?
    private var pollTimer: Timer?
    private var inFlight = false
    private var pendingFetchAfterInFlight = false
    private var lastRequestedStart = -1
    private var lastRequestedCount = -1
    private var lastRequestedTail = false
    private var lastRequestedFilterKey = ""
    private var inFlightFilterKey = ""
    private var inFlightStartTime: CFTimeInterval = 0
    private var lastFetchDuration: CFTimeInterval = 0.20
    private var lastErrorText: String?

    private var totalRows = 0
    private var unfilteredRows = 0
    private var currentWindowStart = 0
    private var currentEvents: [TraceEvent] = []
    private var scrollOffset: CGFloat = 0
    private var scrollSamples: [(time: CFTimeInterval, offset: CGFloat)] = []
    private var isDraggingScrollbar = false
    private var scrollbarDragOffset: CGFloat = 0
    private var isFilterPanelExpanded = false
    private var activeFilterIndex = 0
    private var isSyncingFilterInput = false
    private var filterClauses: [FilterClause] = []
    private var pendingCellFilterContext: CellFilterContext?
    private var isCapturePaused = false

    private let toolbarHeight: CGFloat = 58
    private let headerHeight: CGFloat = 30
    private let rowHeight: CGFloat = 26
    private let horizontalInset: CGFloat = 18
    private let scrollbarWidth: CGFloat = 9
    private let scrollbarTrailingInset: CGFloat = 4
    private let scrollbarHitSlop: CGFloat = 5
    private let overscanScreens: CGFloat = 2
    private let maxPrefetchRows = 512
    private let minPrefetchRows = 120
    private let filterPillSize = CGSize(width: 260, height: 28)
    private let pauseButtonSize = CGSize(width: 28, height: 28)
    private let filterPanelSize = CGSize(width: 460, height: 238)
    private let filterValueFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let filterCaretWidth: CGFloat = 1
    private let maxFilterClauseRows = 6

    private let columns: [(title: String, width: CGFloat, alignment: CATextLayerAlignmentMode)] = [
        ("Time", 0.12, .left),
        ("Event", 0.14, .left),
        ("PID", 0.07, .right),
        ("Process", 0.17, .left),
        ("Path", 0.28, .left),
        ("Detail", 0.22, .left)
    ]

    init(outerframeHost: OuterframeHost, appConnection: OuterframeAppConnection) {
        self.outerframeHost = outerframeHost
        self.appConnection = appConnection
        super.init()
        retainedSelf = self
    }

    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage) {
        switch message {
        case .initializeContent(let arguments):
            outerframeHost.configure(url: arguments.url ?? "",
                                     bundleUrl: arguments.bundleUrl ?? "",
                                     proxyHost: arguments.proxy?.host,
                                     proxyPort: arguments.proxy?.port ?? 0,
                                     proxyUsername: arguments.proxy?.username,
                                     proxyPassword: arguments.proxy?.password)
            appearance = arguments.appearance ?? NSAppearance.currentDrawing()
            currentSize = arguments.contentSize ?? currentSize
            configureNetworking()
            configureLayersIfNeeded()
            updateLayout()
            updateColors()
            registerRootLayerIfNeeded()
            updateTextInputState()
            startPolling()
            fetchVisibleWindow(force: true)

        case .resizeContent(let size):
            currentSize = size
            resetScrollPrediction()
            clampScrollOffset()
            updateLayout()
            fetchVisibleWindow(force: true)

        case .systemAppearanceUpdate(let appearance):
            self.appearance = appearance
            updateColors()

        case .scrollWheelEvent(let point, let delta, _, _, _, let hasPreciseScrollingDeltas):
            guard rowsClipLayer.frame.contains(tableLayer.convert(point, from: rootLayer)) else { return }
            let multiplier = hasPreciseScrollingDeltas ? CGFloat(1) : rowHeight
            scrollOffset -= delta.y * multiplier
            clampScrollOffset()
            recordScrollSample()
            updateLayout()
            fetchVisibleWindow(force: false)

        case .mouseDown(let point, let modifierFlags, let clickCount):
            if !handleToolbarMouseDown(at: point),
               !handleFilterMouseDown(at: point, modifierFlags: modifierFlags, clickCount: clickCount) {
                _ = handleScrollbarMouseDown(at: point)
            }

        case .mouseDragged(let point, _):
            _ = handleScrollbarMouseDragged(to: point)

        case .mouseUp(let point, _):
            _ = handleScrollbarMouseUp(at: point)

        case .rightMouseDown(let point, _, _):
            handleCellContextMenu(at: point)

        case .contextMenuItemSelected(let menuID, let itemID):
            handleContextMenuSelection(menuID: menuID, itemID: itemID)

        case .keyDown(let keyCode, let characters, _, _, _):
            if !handleFilterKeyDown(keyCode: keyCode, characters: characters) {
                handleKeyDown(keyCode: keyCode)
            }

        case .textInput(let text, let hasReplacementRange, let replacementLocation, let replacementLength):
            _ = handleFilterTextInput(text,
                                      hasReplacementRange: hasReplacementRange,
                                      replacementLocation: replacementLocation,
                                      replacementLength: replacementLength)

        case .setMarkedText:
            break

        case .unmarkText:
            break

        case .textCommand(let command):
            _ = handleFilterTextCommand(command)

        case .setCursorPosition(let fieldID, let position, let modifySelection):
            guard fieldID == Self.filterFieldID else { return }
            setFilterPanelExpanded(true)
            filterInputController.setCursorPosition(Int(position), modifySelection: modifySelection)

        case .textInputFocus(let fieldID, let hasFocus):
            guard fieldID == Self.filterFieldID else { return }
            if hasFocus {
                setFilterPanelExpanded(true)
                syncFilterInputToActiveClause(moveCursorToEnd: false)
            } else {
                setFilterPanelExpanded(false)
            }

        case .accessibilitySnapshotRequest(let requestID):
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID,
                                                             snapshot: accessibilitySnapshot())

        case .shutdown:
            stopPolling()
            retainedSelf = nil

        default:
            break
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
        stopPolling()
        retainedSelf = nil
    }

    private func configureNetworking() {
        if let base = outerframeHost.pluginBaseURL() {
            apiEndpoint = URL(string: "/api/events", relativeTo: base)?.absoluteURL
            captureEndpoint = URL(string: "/api/capture", relativeTo: base)?.absoluteURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        outerframeHost.applyProxy(to: configuration)
        urlSession = URLSession(configuration: configuration)
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchVisibleWindow(force: true)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func configureLayersIfNeeded() {
        guard tableLayer.superlayer == nil else { return }

        rootLayer.masksToBounds = true
        rootLayer.addSublayer(tableLayer)
        rootLayer.addSublayer(toolbarLayer)
        rootLayer.addSublayer(headerLayer)
        rootLayer.addSublayer(headerBorderLayer)
        toolbarLayer.addSublayer(titleLayer)
        toolbarLayer.addSublayer(statusLayer)
        toolbarLayer.addSublayer(pauseButtonLayer)
        pauseButtonLayer.addSublayer(pauseButtonIconLayer)
        tableLayer.addSublayer(rowsClipLayer)
        tableLayer.addSublayer(scrollbarTrackLayer)
        scrollbarTrackLayer.addSublayer(scrollbarThumbLayer)
        rootLayer.addSublayer(filterPillLayer)
        rootLayer.addSublayer(filterPanelLayer)
        filterPillLayer.addSublayer(filterPillTextLayer)

        titleLayer.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLayer.fontSize = 15
        titleLayer.contentsScale = 2
        titleLayer.truncationMode = .end
        titleLayer.string = "Outer Trace"

        statusLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLayer.fontSize = 12
        statusLayer.contentsScale = 2
        statusLayer.truncationMode = .end

        pauseButtonLayer.cornerRadius = pauseButtonSize.height / 2
        pauseButtonLayer.masksToBounds = true
        pauseButtonIconLayer.contentsGravity = .resizeAspect
        pauseButtonIconLayer.contentsScale = 2

        filterPillLayer.cornerRadius = 6
        filterPillLayer.borderWidth = 1
        filterPillLayer.zPosition = 300
        filterPillTextLayer.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        filterPillTextLayer.fontSize = 12
        filterPillTextLayer.contentsScale = 2
        filterPillTextLayer.truncationMode = .middle

        filterPanelLayer.cornerRadius = 8
        filterPanelLayer.borderWidth = 1
        filterPanelLayer.zPosition = 310
        filterPanelLayer.isHidden = true

        filterRowLayers = (0..<maxFilterClauseRows).map { _ in
            let layer = CALayer()
            layer.cornerRadius = 5
            filterPanelLayer.addSublayer(layer)
            return layer
        }
        filterSelectionLayer.backgroundColor = CGColor.clear
        filterSelectionLayer.cornerRadius = 0
        filterSelectionLayer.isHidden = true
        filterPanelLayer.addSublayer(filterSelectionLayer)
        filterColumnLayers = (0..<maxFilterClauseRows).map { _ in
            let layer = makeTextLayer(size: 12, weight: .medium)
            filterPanelLayer.addSublayer(layer)
            return layer
        }
        filterOperationLayers = (0..<maxFilterClauseRows).map { _ in
            let layer = makeTextLayer(size: 12, weight: .regular)
            filterPanelLayer.addSublayer(layer)
            return layer
        }
        filterValueLayers = (0..<maxFilterClauseRows).map { _ in
            let layer = makeTextLayer(size: 12, weight: .regular)
            filterPanelLayer.addSublayer(layer)
            return layer
        }
        filterRemoveLayers = (0..<maxFilterClauseRows).map { _ in
            let layer = makeTextLayer(size: 13, weight: .semibold, alignment: .center)
            layer.string = "-"
            filterPanelLayer.addSublayer(layer)
            return layer
        }
        filterAddLayer.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        filterAddLayer.fontSize = 12
        filterAddLayer.contentsScale = 2
        filterAddLayer.string = "+ Add filter"
        filterPanelLayer.addSublayer(filterAddLayer)

        headerTextLayers = columns.map { column in
            let layer = makeTextLayer(size: 12, weight: .semibold, alignment: column.alignment)
            layer.string = column.title
            headerLayer.addSublayer(layer)
            return layer
        }
        headerSeparatorLayers = columns.dropLast().map { _ in
            let layer = CALayer()
            headerLayer.addSublayer(layer)
            return layer
        }

        scrollbarTrackLayer.cornerRadius = scrollbarWidth / 2
        scrollbarThumbLayer.cornerRadius = scrollbarWidth / 2
        rowsClipLayer.masksToBounds = true
    }

    private func makeTextLayer(size: CGFloat,
                               weight: NSFont.Weight,
                               alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.contentsScale = 2
        layer.alignmentMode = alignment
        layer.truncationMode = .end
        return layer
    }

    private func makeRowLayers() -> RowLayers {
        let container = CALayer()
        let background = CALayer()
        let time = makeTextLayer(size: 12, weight: .regular)
        let type = makeTextLayer(size: 12, weight: .medium)
        let pid = makeTextLayer(size: 12, weight: .regular, alignment: .right)
        let process = makeTextLayer(size: 12, weight: .regular)
        let path = makeTextLayer(size: 12, weight: .regular)
        let detail = makeTextLayer(size: 12, weight: .regular)

        background.cornerRadius = 4
        container.addSublayer(background)
        container.addSublayer(time)
        container.addSublayer(type)
        container.addSublayer(pid)
        container.addSublayer(process)
        container.addSublayer(path)
        container.addSublayer(detail)
        rowsClipLayer.addSublayer(container)

        let row = RowLayers(container: container,
                            background: background,
                            time: time,
                            type: type,
                            pid: pid,
                            process: process,
                            path: path,
                            detail: detail)
        applyColors(to: row)
        return row
    }

    private func updateLayout() {
        withoutImplicitAnimations {
            let width = max(currentSize.width, 1)
            let height = max(currentSize.height, 1)
            rootLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))

            toolbarLayer.frame = CGRect(x: 0,
                                        y: max(height - toolbarHeight, 0),
                                        width: width,
                                        height: toolbarHeight)

            let tableHeight = max(height - toolbarHeight, 1)
            tableLayer.frame = CGRect(x: 0, y: 0, width: width, height: tableHeight)
            let scrollbarX = width - scrollbarTrailingInset - scrollbarWidth
            headerLayer.frame = CGRect(x: horizontalInset,
                                       y: tableHeight - headerHeight,
                                       width: max(scrollbarX - horizontalInset - 8, 1),
                                       height: headerHeight)
            let scale = max(headerLayer.contentsScale, 1)
            let borderHeight = max(1 / scale, 0.5)
            headerBorderLayer.frame = CGRect(x: headerLayer.frame.minX,
                                             y: headerLayer.frame.minY - borderHeight,
                                             width: headerLayer.frame.width,
                                             height: borderHeight)
            rowsClipLayer.frame = CGRect(x: horizontalInset,
                                         y: 0,
                                         width: max(scrollbarX - horizontalInset - 8, 1),
                                         height: max(tableHeight - headerHeight, 1))
            scrollbarTrackLayer.frame = CGRect(x: scrollbarX,
                                               y: 0,
                                               width: scrollbarWidth,
                                               height: rowsClipLayer.bounds.height)

            layoutColumnHeaders()
            updateRowLayerCount()
            layoutRows()
            layoutScrollbar()
            layoutFilterUI()
            layoutToolbarTitle()
            updateStatusText()
        }
    }

    private func layoutToolbarTitle() {
        let titleMaxX = max(pauseButtonLayer.frame.minX - 16, horizontalInset + 80)
        let titleWidth = max(titleMaxX - horizontalInset, 1)
        titleLayer.frame = CGRect(x: horizontalInset,
                                  y: 31,
                                  width: titleWidth,
                                  height: 18)
        statusLayer.frame = CGRect(x: horizontalInset,
                                   y: 12,
                                   width: titleWidth,
                                   height: 16)
    }

    private func layoutFilterUI() {
        let width = rootLayer.bounds.width
        let height = rootLayer.bounds.height
        let trailingControlInset = horizontalInset + scrollbarTrailingInset
        let pillX = max(width - trailingControlInset - filterPillSize.width - scrollbarWidth - 4, horizontalInset)
        let pillY = max(height - toolbarHeight + (toolbarHeight - filterPillSize.height) / 2, 0)
        filterPillLayer.frame = CGRect(x: pillX,
                                       y: pillY,
                                       width: filterPillSize.width,
                                       height: filterPillSize.height)
        filterPillTextLayer.frame = filterPillLayer.bounds.insetBy(dx: 10, dy: 7)

        pauseButtonLayer.frame = CGRect(x: max(pillX - pauseButtonSize.width - 8, horizontalInset),
                                        y: (toolbarHeight - pauseButtonSize.height) / 2,
                                        width: pauseButtonSize.width,
                                        height: pauseButtonSize.height)
        pauseButtonIconLayer.frame = pauseButtonLayer.bounds.insetBy(dx: 2, dy: 2)

        filterPanelLayer.frame = CGRect(x: max(width - trailingControlInset - filterPanelSize.width - scrollbarWidth - 4, horizontalInset),
                                        y: max(pillY - filterPanelSize.height - 6, 8),
                                        width: filterPanelSize.width,
                                        height: filterPanelSize.height)
        filterPanelLayer.isHidden = !isFilterPanelExpanded

        for index in 0..<maxFilterClauseRows {
            let y = filterPanelLayer.bounds.height - 36 - CGFloat(index) * 32
            filterRowLayers[index].frame = CGRect(x: 8, y: y - 5, width: filterPanelLayer.bounds.width - 16, height: 28)
            filterColumnLayers[index].frame = CGRect(x: 14, y: y, width: 76, height: 18)
            filterOperationLayers[index].frame = CGRect(x: 98, y: y, width: 92, height: 18)
            filterValueLayers[index].frame = CGRect(x: 202, y: y, width: filterPanelLayer.bounds.width - 242, height: 18)
            filterRemoveLayers[index].frame = CGRect(x: filterPanelLayer.bounds.width - 32, y: y - 1, width: 18, height: 18)
        }
        filterAddLayer.frame = CGRect(x: 14, y: 12, width: 140, height: 18)
        updateFilterText()
    }

    private func layoutColumnHeaders() {
        let frames = columnFrames(in: headerLayer.bounds.width)
        for (index, frame) in frames.enumerated() where index < headerTextLayers.count {
            headerTextLayers[index].frame = frame.insetBy(dx: 6, dy: 7)
        }
        let separatorHeight: CGFloat = 14
        let separatorY = (headerHeight - separatorHeight) / 2
        for (index, separator) in headerSeparatorLayers.enumerated() where index < frames.count - 1 {
            separator.frame = CGRect(x: frames[index].maxX,
                                     y: separatorY,
                                     width: 1 / max(headerLayer.contentsScale, 1),
                                     height: separatorHeight)
        }
    }

    private func layoutRows() {
        let frames = columnFrames(in: rowsClipLayer.bounds.width)
        for (index, row) in rowLayers.enumerated() {
            let globalIndex = currentWindowStart + index
            let rowTopFromViewportTop = CGFloat(globalIndex) * rowHeight - scrollOffset
            row.container.frame = CGRect(x: 0,
                                         y: rowsClipLayer.bounds.height - rowTopFromViewportTop - rowHeight,
                                         width: rowsClipLayer.bounds.width,
                                         height: rowHeight)
            row.background.frame = row.container.bounds.insetBy(dx: 0, dy: 1)
            row.time.frame = frames[0].insetBy(dx: 6, dy: 6)
            row.type.frame = frames[1].insetBy(dx: 6, dy: 6)
            row.pid.frame = frames[2].insetBy(dx: 6, dy: 6)
            row.process.frame = frames[3].insetBy(dx: 6, dy: 6)
            row.path.frame = frames[4].insetBy(dx: 6, dy: 6)
            row.detail.frame = frames[5].insetBy(dx: 6, dy: 6)
        }
    }

    private func layoutScrollbar() {
        let viewportHeight = rowsClipLayer.bounds.height
        let contentHeight = CGFloat(totalRows) * rowHeight
        let maxOffset = max(contentHeight - viewportHeight, 0)
        scrollbarTrackLayer.isHidden = maxOffset <= 0
        if maxOffset <= 0 {
            scrollbarThumbLayer.frame = CGRect(x: 0, y: 0, width: scrollbarWidth, height: viewportHeight)
            return
        }

        let thumbHeight = max((viewportHeight / contentHeight) * viewportHeight, 32)
        let travel = max(viewportHeight - thumbHeight, 0)
        let y = viewportHeight - thumbHeight - (scrollOffset / maxOffset) * travel
        scrollbarThumbLayer.frame = CGRect(x: 0, y: y, width: scrollbarWidth, height: thumbHeight)
    }

    private func handleScrollbarMouseDown(at point: CGPoint) -> Bool {
        guard !scrollbarTrackLayer.isHidden,
              maxScrollOffset() > 0 else {
            return false
        }

        let trackPoint = scrollbarTrackLayer.convert(point, from: rootLayer)
        let hitBounds = scrollbarTrackLayer.bounds.insetBy(dx: -scrollbarHitSlop, dy: 0)
        guard hitBounds.contains(trackPoint) else {
            return false
        }

        let thumbHitFrame = scrollbarThumbLayer.frame.insetBy(dx: -scrollbarHitSlop, dy: 0)
        if thumbHitFrame.contains(trackPoint) {
            isDraggingScrollbar = true
            scrollbarDragOffset = min(max(trackPoint.y - scrollbarThumbLayer.frame.minY, 0),
                                      scrollbarThumbLayer.frame.height)
            return true
        }

        let targetThumbY = trackPoint.y - scrollbarThumbLayer.bounds.height * 0.5
        setScrollOffsetForScrollbarThumbY(targetThumbY)
        isDraggingScrollbar = true
        scrollbarDragOffset = scrollbarThumbLayer.bounds.height * 0.5
        return true
    }

    private func handleScrollbarMouseDragged(to point: CGPoint) -> Bool {
        guard isDraggingScrollbar else { return false }
        let trackPoint = scrollbarTrackLayer.convert(point, from: rootLayer)
        setScrollOffsetForScrollbarThumbY(trackPoint.y - scrollbarDragOffset)
        return true
    }

    private func handleScrollbarMouseUp(at point: CGPoint) -> Bool {
        let wasDragging = isDraggingScrollbar
        isDraggingScrollbar = false
        scrollbarDragOffset = 0
        return wasDragging && scrollbarTrackLayer.bounds.insetBy(dx: -scrollbarHitSlop, dy: 0)
            .contains(scrollbarTrackLayer.convert(point, from: rootLayer))
    }

    private func handleToolbarMouseDown(at point: CGPoint) -> Bool {
        let toolbarPoint = toolbarLayer.convert(point, from: rootLayer)
        guard pauseButtonLayer.frame.insetBy(dx: -4, dy: -4).contains(toolbarPoint) else {
            return false
        }
        setCapturePaused(!isCapturePaused)
        return true
    }

    private func setScrollOffsetForScrollbarThumbY(_ thumbY: CGFloat) {
        let trackHeight = scrollbarTrackLayer.bounds.height
        let thumbHeight = scrollbarThumbLayer.bounds.height
        let travel = max(trackHeight - thumbHeight, 0)
        guard travel > 0 else { return }

        let clampedThumbY = min(max(thumbY, 0), travel)
        let normalizedFromTop = (travel - clampedThumbY) / travel
        scrollOffset = normalizedFromTop * maxScrollOffset()
        clampScrollOffset()
        recordScrollSample()
        updateLayout()
        fetchVisibleWindow(force: false)
    }

    private func handleFilterMouseDown(at point: CGPoint,
                                       modifierFlags: NSEvent.ModifierFlags,
                                       clickCount: Int) -> Bool {
        if filterPillLayer.frame.contains(point) {
            setFilterPanelExpanded(!isFilterPanelExpanded)
            if isFilterPanelExpanded {
                syncFilterInputToActiveClause(moveCursorToEnd: true)
            }
            updateLayout()
            return true
        }

        if isFilterPanelExpanded && filterPanelLayer.frame.contains(point) {
            let panelPoint = filterPanelLayer.convert(point, from: rootLayer)
            if filterAddLayer.frame.insetBy(dx: -8, dy: -6).contains(panelPoint) {
                appendFilterClause()
                return true
            }
            for index in 0..<min(filterClauses.count, maxFilterClauseRows) {
                if filterRemoveLayers[index].frame.insetBy(dx: -6, dy: -6).contains(panelPoint) {
                    removeFilterClause(at: index)
                    return true
                }
                if filterColumnLayers[index].frame.insetBy(dx: -6, dy: -5).contains(panelPoint) {
                    activeFilterIndex = index
                    cycleFilterColumn(at: index)
                    return true
                }
                if filterOperationLayers[index].frame.insetBy(dx: -6, dy: -5).contains(panelPoint) {
                    activeFilterIndex = index
                    cycleFilterOperation(at: index)
                    return true
                }
                let didHitValue = filterValueLayers[index].frame.insetBy(dx: -6, dy: -5).contains(panelPoint)
                if filterRowLayers[index].frame.contains(panelPoint) || didHitValue {
                    let wasFocused = filterInputController.isFocused && activeFilterIndex == index
                    activeFilterIndex = index
                    syncFilterInputToActiveClause(moveCursorToEnd: !didHitValue)
                    if didHitValue {
                        let characterIndex = characterIndexForFilterValue(panelPoint: panelPoint, rowIndex: index)
                        switch clickCount {
                        case 3...:
                            filterInputController.selectAll()
                        case 2:
                            filterInputController.selectWord(at: characterIndex)
                        default:
                            let modifySelection = modifierFlags.contains(.shift) && wasFocused
                            filterInputController.setCursorPosition(characterIndex, modifySelection: modifySelection)
                        }
                    }
                    updateFilterText()
                    updateTextInputState()
                    return true
                }
            }
            return true
        }

        if isFilterPanelExpanded {
            setFilterPanelExpanded(false)
            updateLayout()
        }
        return false
    }

    private func handleCellContextMenu(at point: CGPoint) {
        guard let hit = cellFilterHit(at: point),
              !hit.value.isEmpty else {
            return
        }

        let menuID = UUID()
        pendingCellFilterContext = CellFilterContext(menuID: menuID,
                                                     column: hit.column,
                                                     value: hit.value)
        let value = displayValue(hit.value, maxLength: 80)
        outerframeHost.showContextMenu(
            menuID: menuID,
            items: [
                OuterframeContextMenuItem(id: "include",
                                          title: "Include \(hit.column.title) is \"\(value)\""),
                OuterframeContextMenuItem(id: "exclude",
                                          title: "Exclude \(hit.column.title) is \"\(value)\"")
            ],
            at: point
        )
    }

    private func handleContextMenuSelection(menuID: UUID, itemID: String) {
        guard let context = pendingCellFilterContext,
              context.menuID == menuID else {
            return
        }
        pendingCellFilterContext = nil

        switch itemID {
        case "include":
            addFilterClause(FilterClause(column: context.column,
                                         operation: .equals,
                                         value: context.value))
        case "exclude":
            addFilterClause(FilterClause(column: context.column,
                                         operation: .notEquals,
                                         value: context.value))
        default:
            break
        }
    }

    private func cellFilterHit(at point: CGPoint) -> (column: FilterColumn, value: String)? {
        let pointInRows = rowsClipLayer.convert(point, from: rootLayer)
        guard rowsClipLayer.bounds.contains(pointInRows) else { return nil }

        let columnFrames = columnFrames(in: rowsClipLayer.bounds.width)
        guard let columnIndex = columnFrames.firstIndex(where: { $0.contains(CGPoint(x: pointInRows.x, y: 0)) }),
              let column = filterColumnForVisibleColumn(at: columnIndex) else {
            return nil
        }

        for (rowIndex, row) in rowLayers.enumerated() where rowIndex < currentEvents.count {
            guard !row.container.isHidden,
                  row.container.frame.contains(pointInRows) else {
                continue
            }
            return (column, filterValue(for: currentEvents[rowIndex], column: column))
        }
        return nil
    }

    private func filterColumnForVisibleColumn(at index: Int) -> FilterColumn? {
        switch index {
        case 0: return .time
        case 1: return .event
        case 2: return .pid
        case 3: return .process
        case 4: return .path
        case 5: return .detail
        default: return nil
        }
    }

    private func filterValue(for event: TraceEvent, column: FilterColumn) -> String {
        switch column {
        case .time:
            return event.time
        case .event:
            return event.type
        case .pid:
            return event.pid > 0 ? String(event.pid) : ""
        case .ppid:
            return event.ppid > 0 ? String(event.ppid) : ""
        case .process:
            return event.process
        case .path:
            return event.path
        case .detail:
            return event.detail
        }
    }

    private func displayValue(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        let end = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<end]) + "..."
    }

    private func handleFilterKeyDown(keyCode: UInt16, characters: String) -> Bool {
        guard isFilterPanelExpanded else { return false }

        switch keyCode {
        case 53:
            setFilterPanelExpanded(false)
            updateLayout()
            return true
        case 48:
            if !filterClauses.isEmpty {
                activeFilterIndex = (activeFilterIndex + 1) % filterClauses.count
                syncFilterInputToActiveClause(moveCursorToEnd: true)
            }
            updateFilterText()
            updateTextInputState()
            return true
        case 36, 76:
            applyFilterChange()
            return true
        default:
            return true
        }
    }

    private func handleFilterTextInput(_ text: String,
                                       hasReplacementRange: Bool,
                                       replacementLocation: UInt64,
                                       replacementLength: UInt64) -> Bool {
        guard isFilterPanelExpanded,
              !text.isEmpty else {
            return false
        }
        filterInputController.insertText(text,
                                         replacementRange: replacementRange(hasReplacementRange: hasReplacementRange,
                                                                            location: replacementLocation,
                                                                            length: replacementLength))
        return true
    }

    private func handleFilterTextCommand(_ command: String) -> Bool {
        guard isFilterPanelExpanded else { return false }

        switch command {
        case "insertTab:", "insertTab":
            if !filterClauses.isEmpty {
                activeFilterIndex = (activeFilterIndex + 1) % filterClauses.count
                syncFilterInputToActiveClause(moveCursorToEnd: true)
            }
            updateFilterText()
            updateTextInputState()
            return true
        case "insertNewline:", "insertNewline":
            applyFilterChange()
            return true
        case "cancelOperation:", "cancelOperation":
            setFilterPanelExpanded(false)
            updateLayout()
            return true
        default:
            filterInputController.performCommand(command)
            return true
        }
    }

    private func setActiveFilterValue(_ value: String) {
        guard activeFilterIndex >= 0, activeFilterIndex < filterClauses.count else { return }
        filterClauses[activeFilterIndex].value = value
    }

    private func appendFilterClause() {
        guard filterClauses.count < maxFilterClauseRows else { return }
        addFilterClause(FilterClause(column: .detail, operation: .contains, value: ""))
    }

    private func addFilterClause(_ clause: FilterClause) {
        if filterClauses.count < maxFilterClauseRows {
            filterClauses.append(clause)
            activeFilterIndex = filterClauses.count - 1
        } else if filterClauses.indices.contains(activeFilterIndex) {
            filterClauses[activeFilterIndex] = clause
        } else if !filterClauses.isEmpty {
            filterClauses[filterClauses.count - 1] = clause
            activeFilterIndex = filterClauses.count - 1
        }
        syncFilterInputToActiveClause(moveCursorToEnd: true)
        applyFilterChange()
    }

    private func removeFilterClause(at index: Int) {
        guard index >= 0, index < filterClauses.count else { return }
        filterClauses.remove(at: index)
        activeFilterIndex = min(activeFilterIndex, max(filterClauses.count - 1, 0))
        syncFilterInputToActiveClause(moveCursorToEnd: true)
        applyFilterChange()
    }

    private func cycleFilterColumn(at index: Int) {
        guard index >= 0, index < filterClauses.count else { return }
        let columns = FilterColumn.allCases
        let current = columns.firstIndex(of: filterClauses[index].column) ?? 0
        filterClauses[index].column = columns[(current + 1) % columns.count]
        syncFilterInputToActiveClause(moveCursorToEnd: false)
        applyFilterChange()
    }

    private func cycleFilterOperation(at index: Int) {
        guard index >= 0, index < filterClauses.count else { return }
        let operations = FilterOperation.allCases
        let current = operations.firstIndex(of: filterClauses[index].operation) ?? 0
        filterClauses[index].operation = operations[(current + 1) % operations.count]
        syncFilterInputToActiveClause(moveCursorToEnd: false)
        applyFilterChange()
    }

    private func ensureEditableFilterClause() {
        if filterClauses.isEmpty {
            filterClauses.append(FilterClause(column: .detail, operation: .contains, value: ""))
            activeFilterIndex = 0
        } else {
            activeFilterIndex = min(max(activeFilterIndex, 0), filterClauses.count - 1)
        }
    }

    private func replacementRange(hasReplacementRange: Bool,
                                  location: UInt64,
                                  length: UInt64) -> Range<Int>? {
        guard hasReplacementRange,
              location <= UInt64(Int.max),
              length <= UInt64(Int.max) else {
            return nil
        }
        let start = Int(location)
        let end = min(start + Int(length), filterInputController.text.count)
        return min(start, end)..<end
    }

    private func applyFilterChange() {
        scrollOffset = 0
        resetScrollPrediction()
        lastRequestedStart = -1
        lastRequestedCount = -1
        lastRequestedTail = false
        lastRequestedFilterKey = ""
        updateFilterText()
        updateLayout()
        updateTextInputState()
        fetchVisibleWindow(force: true)
    }

    private func setCapturePaused(_ paused: Bool) {
        guard isCapturePaused != paused else { return }
        isCapturePaused = paused
        updateCaptureButtonAppearance()

        guard let captureEndpoint,
              let urlSession else { return }
        var components = URLComponents(url: captureEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "paused", value: paused ? "1" : "0")]
        guard let url = components?.url else { return }

        urlSession.dataTask(with: url) { [weak self] _, _, error in
            Task { @MainActor in
                if let error {
                    self?.lastErrorText = error.localizedDescription
                    self?.updateStatusText()
                    self?.updateColors()
                } else if paused {
                    self?.lastErrorText = nil
                    self?.updateStatusText()
                    self?.fetchVisibleWindow(force: true)
                } else {
                    self?.lastErrorText = nil
                    self?.lastRequestedStart = -1
                    self?.lastRequestedCount = -1
                    self?.lastRequestedTail = false
                    self?.fetchVisibleWindow(force: true)
                }
            }
        }.resume()
    }

    private func setFilterPanelExpanded(_ expanded: Bool) {
        guard isFilterPanelExpanded != expanded else {
            updateTextInputState()
            return
        }
        isFilterPanelExpanded = expanded
        if expanded {
            ensureEditableFilterClause()
            syncFilterInputToActiveClause(moveCursorToEnd: false)
        } else {
            filterInputController.blur()
        }
        updateTextInputState()
    }

    private func syncFilterInputToActiveClause(moveCursorToEnd: Bool) {
        isSyncingFilterInput = true
        let value = activeFilterValue()
        filterInputController.setText(value)
        filterInputController.focus()
        if moveCursorToEnd {
            filterInputController.setCursorPosition(value.count, modifySelection: false)
        }
        isSyncingFilterInput = false
        updateEditingCapabilities()
    }

    func textInputControllerDidChangeState() {
        guard !isSyncingFilterInput else { return }

        if filterInputController.text != activeFilterValue() {
            setActiveFilterValue(filterInputController.text)
            applyFilterChange()
        } else {
            updateFilterText()
            updateLayout()
            updateTextInputState()
        }
        updateEditingCapabilities()
    }

    private func updateTextInputState() {
        outerframeHost.setInputMode(isFilterPanelExpanded ? .textInput : .rawKeys)
        updateFilterSelectionLayer()
        guard isFilterPanelExpanded,
              activeFilterIndex >= 0,
              activeFilterIndex < filterValueLayers.count,
              activeFilterIndex < filterClauses.count,
              !filterInputController.hasSelection else {
            outerframeHost.sendTextCursorUpdate(cursors: [])
            updateEditingCapabilities()
            return
        }

        let valueLayer = filterValueLayers[activeFilterIndex]
        let line = makeFilterValueLine(for: filterInputController.text)
        let cursorOffset = offsetForFilterValueCharacter(line: line,
                                                         text: filterInputController.text,
                                                         index: filterInputController.cursorPosition,
                                                         maxWidth: valueLayer.frame.width)
        let contentsScale = max(valueLayer.contentsScale, 1)
        let cursorWidth = max(filterCaretWidth, 1 / contentsScale)
        let cursorX = min(max(valueLayer.frame.minX + cursorOffset, valueLayer.frame.minX),
                          valueLayer.frame.maxX - cursorWidth)
        let panelCaretRect = CGRect(x: cursorX,
                                    y: valueLayer.frame.minY,
                                    width: cursorWidth,
                                    height: valueLayer.frame.height)
        let rootCaretRect = filterPanelLayer.convert(panelCaretRect, to: rootLayer)
        let topLeftY = rootLayer.bounds.height - rootCaretRect.origin.y - rootCaretRect.height
        let cursor = OuterframeContentTextCursorSnapshot(fieldID: Self.filterFieldID,
                                                         rect: CGRect(x: rootCaretRect.origin.x,
                                                                      y: topLeftY,
                                                                      width: rootCaretRect.width,
                                                                      height: rootCaretRect.height),
                                                         visible: true)
        outerframeHost.sendTextCursorUpdate(cursors: [cursor])
        updateEditingCapabilities()
    }

    private func updateFilterSelectionLayer() {
        guard isFilterPanelExpanded,
              activeFilterIndex >= 0,
              activeFilterIndex < filterValueLayers.count,
              activeFilterIndex < filterClauses.count,
              filterInputController.isFocused,
              let range = filterInputController.selectionRange,
              !filterInputController.text.isEmpty else {
            filterSelectionLayer.isHidden = true
            filterSelectionLayer.frame = .zero
            return
        }

        let valueLayer = filterValueLayers[activeFilterIndex]
        let line = makeFilterValueLine(for: filterInputController.text)
        let start = offsetForFilterValueCharacter(line: line,
                                                  text: filterInputController.text,
                                                  index: range.lowerBound,
                                                  maxWidth: valueLayer.frame.width)
        let end = offsetForFilterValueCharacter(line: line,
                                                text: filterInputController.text,
                                                index: range.upperBound,
                                                maxWidth: valueLayer.frame.width)
        let x = valueLayer.frame.minX + min(start, end)
        let width = min(abs(end - start), max(0, valueLayer.frame.maxX - x))
        if width > 0.5 {
            filterSelectionLayer.isHidden = false
            filterSelectionLayer.frame = CGRect(x: x,
                                                y: valueLayer.frame.minY,
                                                width: width,
                                                height: valueLayer.frame.height)
        } else {
            filterSelectionLayer.isHidden = true
            filterSelectionLayer.frame = .zero
        }
    }

    private func makeFilterValueLine(for text: String) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [.font: filterValueFont]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func offsetForFilterValueCharacter(line: CTLine,
                                               text: String,
                                               index: Int,
                                               maxWidth: CGFloat) -> CGFloat {
        let utf16Index = utf16Offset(forCharacterIndex: index, in: text)
        var secondaryOffset: CGFloat = 0
        let primaryOffset = CTLineGetOffsetForStringIndex(line, utf16Index, &secondaryOffset)
        let offset = max(primaryOffset, secondaryOffset)
        return offset.isFinite ? min(max(offset, 0), maxWidth) : 0
    }

    private func characterIndexForFilterValue(panelPoint: CGPoint, rowIndex: Int) -> Int {
        guard rowIndex >= 0, rowIndex < filterValueLayers.count else { return 0 }
        let text = rowIndex == activeFilterIndex ? filterInputController.text : filterClauses[rowIndex].value
        let valueLayer = filterValueLayers[rowIndex]
        let localX = max(0, min(panelPoint.x - valueLayer.frame.minX, valueLayer.frame.width))
        guard !text.isEmpty, valueLayer.frame.width > 0 else { return 0 }
        let line = makeFilterValueLine(for: text)
        let utf16Index = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        if utf16Index == kCFNotFound {
            return text.count
        }
        return characterIndex(forUTF16: utf16Index, in: text)
    }

    private func utf16Offset(forCharacterIndex index: Int, in text: String) -> Int {
        let clamped = max(0, min(index, text.count))
        let stringIndex = text.index(text.startIndex, offsetBy: clamped)
        return text[text.startIndex..<stringIndex].utf16.count
    }

    private func characterIndex(forUTF16 offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.utf16.count))
        let stringIndex = String.Index(utf16Offset: clamped, in: text)
        return text.distance(from: text.startIndex, to: stringIndex)
    }

    private func updateEditingCapabilities() {
        outerframeHost.setPasteboardCapabilities(filterInputController.currentEditingCapabilities())
    }

    private func activeFilterValue() -> String {
        guard activeFilterIndex >= 0, activeFilterIndex < filterClauses.count else { return "" }
        return filterClauses[activeFilterIndex].value
    }

    private func activeFilterClauses() -> [FilterClause] {
        filterClauses.filter { !$0.value.isEmpty }
    }

    private func currentFilterSummary() -> String {
        let parts = activeFilterClauses().map { clause in
            "\(clause.column.title) \(clause.operation.title.lowercased()) \(clause.value)"
        }
        return parts.isEmpty ? "Filter: All events" : parts.joined(separator: "  ")
    }

    private func updateFilterText() {
        withoutImplicitAnimations {
            filterPillTextLayer.string = currentFilterSummary()
            for index in 0..<maxFilterClauseRows {
                let isVisible = index < filterClauses.count
                filterRowLayers[index].isHidden = !isVisible
                filterColumnLayers[index].isHidden = !isVisible
                filterOperationLayers[index].isHidden = !isVisible
                filterValueLayers[index].isHidden = !isVisible
                filterRemoveLayers[index].isHidden = !isVisible
                guard isVisible else { continue }

                let clause = filterClauses[index]
                let prefix = activeFilterIndex == index ? "> " : ""
                filterColumnLayers[index].string = "\(prefix)\(clause.column.title)"
                filterOperationLayers[index].string = clause.operation.title
                filterValueLayers[index].string = clause.value.isEmpty ? "Value" : clause.value
            }
            filterAddLayer.isHidden = filterClauses.count >= maxFilterClauseRows
            updateFilterRowColors()
            updateFilterValueColors()
            updateFilterSelectionLayer()
        }
    }

    private func updateFilterRowColors() {
        appearance?.performAsCurrentDrawingAppearance {
            for index in 0..<maxFilterClauseRows {
                let color = activeFilterIndex == index ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.clear
                filterRowLayers[index].backgroundColor = color.cgColor
            }
        }
    }

    private func updateFilterValueColors() {
        appearance?.performAsCurrentDrawingAppearance {
            let selectedTextBackground = NSColor.selectedTextBackgroundColor
            let inactiveSelectionBase = NSColor.unemphasizedSelectedTextBackgroundColor
            let controlBrightness = NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
            let isLightTheme = controlBrightness > 0.6
            filterSelectionLayer.backgroundColor = filterInputController.isFocused ?
                selectedTextBackground.cgColor :
                inactiveSelectionBase.withAlphaComponent(isLightTheme ? 0.75 : 0.9).cgColor

            for index in 0..<filterValueLayers.count {
                let isPlaceholder = index >= filterClauses.count || filterClauses[index].value.isEmpty
                filterValueLayers[index].foregroundColor = (isPlaceholder ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor
            }
        }
    }

    private func columnFrames(in width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() {
            let columnWidth = index == columns.count - 1 ? max(width - x, 1) : floor(width * column.width)
            frames.append(CGRect(x: x, y: 0, width: columnWidth, height: headerHeight))
            x += columnWidth
        }
        return frames
    }

    private func updateRowLayerCount() {
        let needed = visibleRequestCount()
        while rowLayers.count < needed {
            rowLayers.append(makeRowLayers())
        }
        for (index, row) in rowLayers.enumerated() {
            row.container.isHidden = index >= currentEvents.count
        }
    }

    private func visibleRowRange(for offset: CGFloat) -> (start: Int, end: Int) {
        let viewportHeight = max(rowsClipLayer.bounds.height, rowHeight)
        let start = max(Int(floor(offset / rowHeight)), 0)
        let end = max(Int(ceil((offset + viewportHeight) / rowHeight)), start + 1)
        return (start, end)
    }

    private func visibleStartIndex() -> Int {
        desiredFetchWindow().start
    }

    private func visibleRequestCount() -> Int {
        desiredFetchWindow().count
    }

    private func desiredFetchWindow() -> (start: Int, count: Int) {
        let visibleRows = max(Int(ceil(rowsClipLayer.bounds.height / rowHeight)), 1)
        let currentRange = visibleRowRange(for: scrollOffset)
        let predictedOffset = predictedScrollOffset()
        let predictedRange = visibleRowRange(for: predictedOffset)
        let velocity = currentScrollVelocity()
        let predictedRows = Int(ceil(abs(predictedOffset - scrollOffset) / rowHeight))
        let baseOverscanRows = max(Int(ceil(CGFloat(visibleRows) * overscanScreens)), visibleRows * 2)
        let aheadRows = max(baseOverscanRows, predictedRows + visibleRows * 2)
        let trailingRows = max(visibleRows, baseOverscanRows / 2)

        let unionStart = min(currentRange.start, predictedRange.start)
        let unionEnd = max(currentRange.end, predictedRange.end)
        let rawStart: Int
        let rawEnd: Int
        if velocity > 0 {
            rawStart = unionStart - trailingRows
            rawEnd = unionEnd + aheadRows
        } else if velocity < 0 {
            rawStart = unionStart - aheadRows
            rawEnd = unionEnd + trailingRows
        } else {
            rawStart = unionStart - baseOverscanRows
            rawEnd = unionEnd + baseOverscanRows
        }

        let boundedTotal = max(totalRows, unionEnd)
        var start = max(rawStart, 0)
        var end = min(max(rawEnd, start + minPrefetchRows), boundedTotal)
        if end - start < minPrefetchRows {
            start = max(0, min(start, end - minPrefetchRows))
            end = min(boundedTotal, max(end, start + minPrefetchRows))
        }

        if end - start > maxPrefetchRows {
            if velocity > 0 {
                start = max(0, unionStart - trailingRows)
                end = min(boundedTotal, start + maxPrefetchRows)
            } else if velocity < 0 {
                end = min(boundedTotal, unionEnd + trailingRows)
                start = max(0, end - maxPrefetchRows)
            } else {
                let center = (unionStart + unionEnd) / 2
                start = max(0, center - maxPrefetchRows / 2)
                end = min(boundedTotal, start + maxPrefetchRows)
                start = max(0, end - maxPrefetchRows)
            }
        }

        return (start, max(end - start, 1))
    }

    private func recordScrollSample() {
        let now = CACurrentMediaTime()
        scrollSamples.append((time: now, offset: scrollOffset))
        scrollSamples.removeAll { now - $0.time > 0.25 }
        if scrollSamples.count > 5 {
            scrollSamples.removeFirst(scrollSamples.count - 5)
        }
    }

    private func resetScrollPrediction() {
        scrollSamples.removeAll()
    }

    private func currentScrollVelocity() -> CGFloat {
        let now = CACurrentMediaTime()
        scrollSamples.removeAll { now - $0.time > 0.25 }
        guard let first = scrollSamples.first,
              let last = scrollSamples.last,
              last.time - first.time >= 0.025 else {
            return 0
        }
        let velocity = (last.offset - first.offset) / CGFloat(last.time - first.time)
        return abs(velocity) < 20 ? 0 : velocity
    }

    private func predictionHorizon() -> CFTimeInterval {
        min(max(lastFetchDuration * 2.5, 0.20), 0.75)
    }

    private func predictedScrollOffset() -> CGFloat {
        let velocity = currentScrollVelocity()
        guard velocity != 0 else { return scrollOffset }
        let projected = scrollOffset + velocity * CGFloat(predictionHorizon())
        return min(max(projected, 0), maxScrollOffset())
    }

    private func currentFilterKey() -> String {
        activeFilterClauses()
            .map { "\($0.column.rawValue)\u{1F}\($0.operation.rawValue)\u{1F}\($0.value)" }
            .joined(separator: "\u{1E}")
    }

    private func responseCoversDesiredWindow(responseStart: Int, responseCount: Int) -> Bool {
        if isPinnedToBottom() {
            return responseCount > 0 || totalRows == 0
        }
        let desired = desiredFetchWindow()
        let desiredEnd = min(desired.start + desired.count, totalRows)
        let responseEnd = min(responseStart + responseCount, totalRows)
        if totalRows == 0 {
            return responseCount == 0
        }
        return desired.start >= responseStart && desiredEnd <= responseEnd
    }

    private func fetchVisibleWindow(force: Bool) {
        guard let apiEndpoint,
              let urlSession else { return }

        if inFlight {
            pendingFetchAfterInFlight = true
            return
        }

        let window = desiredFetchWindow()
        let start = window.start
        let count = window.count
        let tail = isPinnedToBottom()
        let filterKey = currentFilterKey()
        if !force &&
            start == lastRequestedStart &&
            count == lastRequestedCount &&
            tail == lastRequestedTail &&
            filterKey == lastRequestedFilterKey {
            return
        }

        var components = URLComponents(url: apiEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "tail", value: tail ? "1" : "0")
        ]
        var queryItems = components?.queryItems ?? []
        let clauses = activeFilterClauses()
        queryItems.append(URLQueryItem(name: "filterCount", value: String(clauses.count)))
        for (index, clause) in clauses.enumerated() {
            queryItems.append(URLQueryItem(name: "f\(index)column", value: clause.column.rawValue))
            queryItems.append(URLQueryItem(name: "f\(index)op", value: clause.operation.rawValue))
            queryItems.append(URLQueryItem(name: "f\(index)value", value: clause.value))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return }

        inFlight = true
        pendingFetchAfterInFlight = false
        lastRequestedStart = start
        lastRequestedCount = count
        lastRequestedTail = tail
        lastRequestedFilterKey = filterKey
        inFlightFilterKey = filterKey
        inFlightStartTime = CACurrentMediaTime()
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            let errorText = error?.localizedDescription
            Task { @MainActor in
                self?.handleFetchResult(data: data, errorText: errorText)
            }
        }.resume()
    }

    private func handleFetchResult(data: Data?, errorText: String?) {
        inFlight = false
        lastFetchDuration = min(max(CACurrentMediaTime() - inFlightStartTime, 0.02), 1.0)
        let responseFilterKey = inFlightFilterKey
        inFlightFilterKey = ""
        if responseFilterKey != currentFilterKey() {
            fetchVisibleWindow(force: true)
            return
        }

        let wasPinnedToBottom = isPinnedToBottom()
        if let errorText {
            lastErrorText = errorText
            updateStatusText()
            return
        }
        guard let data else {
            lastErrorText = "No response from backend"
            updateStatusText()
            return
        }

        do {
            let response = try decodeTraceEventResponse(data)
            let hadPendingFetch = pendingFetchAfterInFlight
            let responseStart = response.start
            totalRows = response.total
            unfilteredRows = response.unfilteredTotal
            if wasPinnedToBottom {
                scrollOffset = maxScrollOffset()
            }
            currentWindowStart = response.start
            currentEvents = response.events
            lastErrorText = nil
            clampScrollOffset()
            updateRows()
            updateLayout()
            let shouldRefetch = !responseCoversDesiredWindow(responseStart: responseStart, responseCount: response.count)
            pendingFetchAfterInFlight = false
            if shouldRefetch || hadPendingFetch {
                fetchVisibleWindow(force: true)
            }
        } catch {
            lastErrorText = "Could not decode binary event response"
            updateStatusText()
        }
    }

    private func updateRows() {
        withoutImplicitAnimations {
            updateRowLayerCount()
            for (index, row) in rowLayers.enumerated() {
                guard index < currentEvents.count else {
                    row.container.isHidden = true
                    continue
                }
                let event = currentEvents[index]
                row.container.isHidden = false
                row.time.string = event.time
                row.type.string = event.type
                row.pid.string = event.pid > 0 ? String(event.pid) : ""
                row.process.string = event.process
                row.path.string = event.path
                row.detail.string = event.detail
                row.background.opacity = ((currentWindowStart + index) % 2 == 0) ? 0.38 : 0
            }
        }
    }

    private func updateStatusText() {
        withoutImplicitAnimations {
            if let lastErrorText {
                statusLayer.string = "Backend unavailable: \(lastErrorText)"
                return
            }
            let shownRows = totalRows
            let denominator = max(unfilteredRows, totalRows)
            let percentage = denominator > 0 ? Int((Double(shownRows) / Double(denominator) * 100).rounded()) : 0
            statusLayer.string = "Showing \(formatCount(shownRows)) of \(formatCount(denominator)) events (\(percentage)%)"
        }
    }

    private func clampScrollOffset() {
        scrollOffset = min(max(scrollOffset, 0), maxScrollOffset())
    }

    private func maxScrollOffset() -> CGFloat {
        let contentHeight = CGFloat(totalRows) * rowHeight
        return max(contentHeight - rowsClipLayer.bounds.height, 0)
    }

    private func isPinnedToBottom() -> Bool {
        totalRows == 0 || scrollOffset >= maxScrollOffset() - 1
    }

    private func handleKeyDown(keyCode: UInt16) {
        resetScrollPrediction()
        switch keyCode {
        case 125:
            scrollOffset += rowHeight
        case 126:
            scrollOffset -= rowHeight
        case 121:
            scrollOffset += rowsClipLayer.bounds.height
        case 116:
            scrollOffset -= rowsClipLayer.bounds.height
        case 115:
            scrollOffset = 0
        case 119:
            scrollOffset = max(CGFloat(totalRows) * rowHeight - rowsClipLayer.bounds.height, 0)
        default:
            return
        }
        clampScrollOffset()
        updateLayout()
        fetchVisibleWindow(force: false)
    }

    private func updateColors() {
        withoutImplicitAnimations {
            appearance?.performAsCurrentDrawingAppearance {
                rootLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
                tableLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
                toolbarLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
                headerLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
                let controlBrightness = NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
                let isLightTheme = controlBrightness > 0.6
                headerBorderLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(isLightTheme ? 0.35 : 0.6).cgColor
                rowsClipLayer.backgroundColor = NSColor.textBackgroundColor.cgColor
                scrollbarTrackLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
                scrollbarThumbLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.36).cgColor
                titleLayer.foregroundColor = NSColor.labelColor.cgColor
                statusLayer.foregroundColor = lastErrorText == nil ? NSColor.secondaryLabelColor.cgColor : NSColor.systemRed.cgColor
                pauseButtonLayer.backgroundColor = NSColor.clear.cgColor
                filterPillLayer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
                filterPillLayer.borderColor = NSColor.separatorColor.cgColor
                filterPillTextLayer.foregroundColor = NSColor.labelColor.cgColor
                filterPanelLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
                filterPanelLayer.borderColor = NSColor.separatorColor.cgColor
                for layer in headerTextLayers {
                    layer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                }
                for layer in headerSeparatorLayers {
                    layer.backgroundColor = NSColor.separatorColor.withAlphaComponent(isLightTheme ? 0.35 : 0.45).cgColor
                }
                for layer in filterColumnLayers {
                    layer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                }
                for layer in filterOperationLayers {
                    layer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                }
                for layer in filterRemoveLayers {
                    layer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                }
                filterAddLayer.foregroundColor = NSColor.controlAccentColor.cgColor
                updateFilterRowColors()
                updateFilterValueColors()
                updateCaptureButtonAppearance()
                for row in rowLayers {
                    applyColors(to: row)
                }
            }
        }
    }

    private func applyColors(to row: RowLayers) {
        appearance?.performAsCurrentDrawingAppearance {
            row.background.backgroundColor = NSColor.controlBackgroundColor.cgColor
            row.time.foregroundColor = NSColor.secondaryLabelColor.cgColor
            row.type.foregroundColor = NSColor.controlAccentColor.cgColor
            row.pid.foregroundColor = NSColor.secondaryLabelColor.cgColor
            row.process.foregroundColor = NSColor.labelColor.cgColor
            row.path.foregroundColor = NSColor.labelColor.cgColor
            row.detail.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func registerRootLayerIfNeeded() {
        guard !didRegisterLayer else { return }
        guard let registerLayer = appConnection.registerLayer else { return }
        registerLayer(rootLayer)
        didRegisterLayer = true
    }

    private func updateCaptureButtonAppearance() {
        appearance?.performAsCurrentDrawingAppearance {
            let symbolName = isCapturePaused ? "play.circle" : "pause.circle.fill"
            let tint = isCapturePaused ? NSColor.labelColor : NSColor.controlAccentColor
            pauseButtonIconLayer.contents = makeSystemSymbolImage(systemSymbolName: symbolName,
                                                                  pointSize: 22,
                                                                  weight: .regular,
                                                                  scale: max(pauseButtonIconLayer.contentsScale, 2),
                                                                  tintColor: tint,
                                                                  appearance: appearance ?? NSAppearance.currentDrawing())
        }
    }

    private func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func accessibilitySnapshot() -> OuterframeAccessibilitySnapshot? {
        var children: [OuterframeAccessibilityNode] = [
            OuterframeAccessibilityNode(identifier: 1,
                                        role: .staticText,
                                        frame: toolbarLayer.convert(statusLayer.frame, to: rootLayer),
                                        label: statusLayer.string as? String ?? "")
        ]

        for (index, event) in currentEvents.enumerated() where index < rowLayers.count && !rowLayers[index].container.isHidden {
            let frameInRoot = rowsClipLayer.convert(rowLayers[index].container.frame, to: rootLayer)
            children.append(OuterframeAccessibilityNode(identifier: UInt32(1000 + index),
                                                        role: .staticText,
                                                        frame: frameInRoot,
                                                        label: "\(event.time) \(event.type) \(event.pid) \(event.process) \(event.detail)"))
        }

        let rootNode = OuterframeAccessibilityNode(identifier: 0,
                                                   role: .container,
                                                   frame: rootLayer.frame,
                                                   label: "Trace event monitor",
                                                   children: children)
        return OuterframeAccessibilitySnapshot(rootNodes: [rootNode])
    }
}
