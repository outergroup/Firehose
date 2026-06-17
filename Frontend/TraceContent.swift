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
    let captureStatus: CaptureStatus
    let events: [TraceEvent]
}

private enum CapturePauseReason: UInt32 {
    case none = 0
    case user = 1
    case lowStorage = 2
}

private struct CaptureStatus {
    let isPaused: Bool
    let pauseReason: CapturePauseReason
    let storageStatusValid: Bool
    let storageIsLow: Bool
    let isUnsupported: Bool
    let unsupportedMessage: String
    let availableStorageBytes: UInt64
    let storageThresholdBytes: UInt64
    let totalStorageBytes: UInt64
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

private struct ProcessTimelineResponse {
    let captureStart: Double
    let captureEnd: Double
    let processCount: Int
    let eventCount: UInt64
    let eventDotBucketCount: Int
    let eventDotMaxCount: Int
    let eventDots: [TimelineEventDot]
    let processes: [TimelineProcess]
}

private struct TimelineEventDot {
    let pid: Int
    let bucketIndex: Int
    let count: Int
    let timestamp: Double
    let filteredIndex: Int?
}

private struct TimelineEventDotHit {
    let pid: Int
    let bucketIndex: Int
    let count: Int
    let timestamp: Double
    let filteredIndex: Int?
    let center: CGPoint
}

private struct TimelineProcess {
    let pid: Int
    let ppid: Int
    let process: String
    let firstTimestamp: Double
    let startTimestamp: Double
    let endTimestamp: Double
    let lastTimestamp: Double
    let eventCount: UInt64
    let openAtStart: Bool
    let isRunning: Bool
    let level: Int
}

private struct TimelineProcessRow {
    let process: TimelineProcess
    let level: Int
}

private struct EventPositionResponse {
    let found: Bool
    let index: Int
    let eventID: UInt64
    let timestamp: Double
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

private struct TableCellSelection {
    let columnTitle: String
    let value: String
}

private struct MachineUnsupportedTextLine {
    let text: String
    let range: Range<Int>
    let frame: CGRect
    let font: NSFont
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
    let captureFlags = headerSize >= 72 ? try data.traceUInt32(at: 40) : 0
    let pauseReasonValue = headerSize >= 72 ? try data.traceUInt32(at: 44) : 0
    let availableStorageBytes = headerSize >= 72 ? try data.traceUInt64(at: 48) : 0
    let storageThresholdBytes = headerSize >= 72 ? try data.traceUInt64(at: 56) : 0
    let totalStorageBytes = headerSize >= 72 ? try data.traceUInt64(at: 64) : 0

    guard magic == 0x4543_5254,
          version == 1 || version == 2 || version == 3 || version == 4,
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
                              captureStatus: captureStatus(flags: captureFlags,
                                                           pauseReasonValue: pauseReasonValue,
                                                           availableStorageBytes: availableStorageBytes,
                                                           storageThresholdBytes: storageThresholdBytes,
                                                           totalStorageBytes: totalStorageBytes),
                              events: events)
}

private func captureStatus(flags: UInt32,
                           pauseReasonValue: UInt32,
                           availableStorageBytes: UInt64,
                           storageThresholdBytes: UInt64,
                           totalStorageBytes: UInt64,
                           unsupportedMessage: String = "") -> CaptureStatus {
    CaptureStatus(isPaused: flags & (1 << 0) != 0,
                  pauseReason: CapturePauseReason(rawValue: pauseReasonValue) ?? .none,
                  storageStatusValid: flags & (1 << 1) != 0,
                  storageIsLow: flags & (1 << 2) != 0,
                  isUnsupported: flags & (1 << 3) != 0,
                  unsupportedMessage: unsupportedMessage,
                  availableStorageBytes: availableStorageBytes,
                  storageThresholdBytes: storageThresholdBytes,
                  totalStorageBytes: totalStorageBytes)
}

private func decodeCaptureStatusResponse(_ data: Data) throws -> CaptureStatus {
    let magic = try data.traceUInt32(at: 0)
    let version = try data.traceUInt16(at: 4)
    let headerSize = Int(try data.traceUInt16(at: 6))
    let flags = try data.traceUInt32(at: 8)
    let pauseReasonValue = try data.traceUInt32(at: 12)
    let availableStorageBytes = try data.traceUInt64(at: 16)
    let storageThresholdBytes = try data.traceUInt64(at: 24)
    let totalStorageBytes = try data.traceUInt64(at: 32)
    let unsupportedMessage = headerSize >= 48 ? try data.traceStringRef32(at: 40) : ""

    guard magic == 0x4353_5254,
          version == 1,
          headerSize >= 48,
          headerSize <= data.count else {
        throw TraceEventDecodeError.invalidFormat
    }

    return captureStatus(flags: flags,
                         pauseReasonValue: pauseReasonValue,
                         availableStorageBytes: availableStorageBytes,
                         storageThresholdBytes: storageThresholdBytes,
                         totalStorageBytes: totalStorageBytes,
                         unsupportedMessage: unsupportedMessage)
}

private func decodeProcessTimelineResponse(_ data: Data) throws -> ProcessTimelineResponse {
    let magic = try data.traceUInt32(at: 0)
    let version = try data.traceUInt16(at: 4)
    let headerSize = Int(try data.traceUInt16(at: 6))
    let captureStart = try data.traceDouble(at: 8)
    let captureEnd = try data.traceDouble(at: 16)
    let processCount = Int(try data.traceUInt32(at: 24))
    let recordSize = Int(try data.traceUInt32(at: 28))
    let eventCount = try data.traceUInt64(at: 32)
    let totalProcessCountValue = headerSize >= 48 ? try data.traceUInt64(at: 40) : UInt64(processCount)
    let dotCount = headerSize >= 64 ? Int(try data.traceUInt32(at: 48)) : 0
    let dotRecordSize = headerSize >= 64 ? Int(try data.traceUInt32(at: 52)) : 0
    let dotBucketCount = headerSize >= 64 ? Int(try data.traceUInt32(at: 56)) : 0
    let dotMaxCount = headerSize >= 64 ? Int(try data.traceUInt32(at: 60)) : 0

    guard magic == 0x5043_5254,
          version == 1 || version == 2 || version == 3 || version == 4 || version == 5,
          headerSize >= 48,
          recordSize >= 64,
          totalProcessCountValue <= UInt64(Int.max),
          headerSize <= data.count,
          processCount <= (data.count - headerSize) / recordSize else {
        throw TraceEventDecodeError.invalidFormat
    }
    let totalProcessCount = Int(totalProcessCountValue)
    let processRecordsEnd = headerSize + processCount * recordSize
    guard processRecordsEnd <= data.count else { throw TraceEventDecodeError.invalidFormat }

    var eventDots: [TimelineEventDot] = []
    if version >= 2 {
        guard headerSize >= 64,
              dotRecordSize >= 12,
              dotCount >= 0,
              dotBucketCount >= 0,
              dotMaxCount >= 0,
              dotCount <= (data.count - processRecordsEnd) / dotRecordSize else {
            throw TraceEventDecodeError.invalidFormat
        }
        eventDots.reserveCapacity(dotCount)
        let maxBucketIndex = max(dotBucketCount - 1, 1)
        let duration = max(captureEnd - captureStart, 0.001)
        for index in 0..<dotCount {
            let offset = processRecordsEnd + index * dotRecordSize
            let bucketIndex = Int(try data.traceUInt32(at: offset + 4))
            let timestamp = dotRecordSize >= 20 ?
                try data.traceDouble(at: offset + 12) :
                captureStart + (Double(bucketIndex) / Double(maxBucketIndex)) * duration
            let filteredIndexValue = dotRecordSize >= 28 ? try data.traceUInt64(at: offset + 20) : UInt64.max
            let filteredIndex = filteredIndexValue <= UInt64(Int.max) ? Int(filteredIndexValue) : nil
            eventDots.append(TimelineEventDot(pid: Int(try data.traceInt32(at: offset + 0)),
                                              bucketIndex: bucketIndex,
                                              count: Int(try data.traceUInt32(at: offset + 8)),
                                              timestamp: timestamp,
                                              filteredIndex: filteredIndex))
        }
    }

    var processes: [TimelineProcess] = []
    processes.reserveCapacity(processCount)
    for index in 0..<processCount {
        let offset = headerSize + index * recordSize
        let flags = try data.traceUInt32(at: offset + 48)
        processes.append(TimelineProcess(pid: Int(try data.traceInt32(at: offset + 0)),
                                         ppid: Int(try data.traceInt32(at: offset + 4)),
                                         process: try data.traceStringRef32(at: offset + 52),
                                         firstTimestamp: try data.traceDouble(at: offset + 8),
                                         startTimestamp: try data.traceDouble(at: offset + 16),
                                         endTimestamp: try data.traceDouble(at: offset + 24),
                                         lastTimestamp: try data.traceDouble(at: offset + 32),
                                         eventCount: try data.traceUInt64(at: offset + 40),
                                         openAtStart: (flags & 1) != 0,
                                         isRunning: (flags & 2) != 0,
                                         level: version >= 5 ? Int(try data.traceUInt16(at: offset + 60)) : 0))
    }

    return ProcessTimelineResponse(captureStart: captureStart,
                                   captureEnd: captureEnd,
                                   processCount: totalProcessCount,
                                   eventCount: eventCount,
                                   eventDotBucketCount: dotBucketCount,
                                   eventDotMaxCount: dotMaxCount,
                                   eventDots: eventDots,
                                   processes: processes)
}

private func decodeEventPositionResponse(_ data: Data) throws -> EventPositionResponse {
    let magic = try data.traceUInt32(at: 0)
    let version = try data.traceUInt16(at: 4)
    let headerSize = Int(try data.traceUInt16(at: 6))
    let indexValue = try data.traceUInt64(at: 8)
    let eventID = try data.traceUInt64(at: 16)
    let timestamp = try data.traceDouble(at: 24)
    let found = try data.traceUInt32(at: 32) != 0

    guard magic == 0x504a_5254,
          version == 1,
          headerSize >= 40,
          headerSize <= data.count,
          (!found || indexValue <= UInt64(Int.max)) else {
        throw TraceEventDecodeError.invalidFormat
    }

    return EventPositionResponse(found: found,
                                 index: found ? Int(indexValue) : 0,
                                 eventID: eventID,
                                 timestamp: timestamp)
}

private func decodeClearLogResponse(_ data: Data) throws -> Bool {
    let magic = try data.traceUInt32(at: 0)
    let version = try data.traceUInt16(at: 4)
    let headerSize = Int(try data.traceUInt16(at: 6))
    let cleared = try data.traceUInt32(at: 8) != 0

    guard magic == 0x434c_5254,
          version == 1,
          headerSize >= 16,
          headerSize <= data.count else {
        throw TraceEventDecodeError.invalidFormat
    }
    return cleared
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

    private struct TimelineRowLayers {
        let container: CALayer
        let background: CALayer
        let name: CATextLayer
        let pid: CATextLayer
        let events: CATextLayer
        let barTrack: CALayer
        let bar: CALayer
    }

    private let outerframeHost: OuterframeHost
    private let appConnection: OuterframeAppConnection
    private var retainedSelf: TraceHandler?
    private var accessibilityNotificationScheduled = false
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
    private let statusLayer = CATextLayer()
    private let toolbarLayer = CALayer()
    private let pauseButtonLayer = CALayer()
    private let pauseButtonIconLayer = CALayer()
    private let clearLogButtonLayer = CALayer()
    private let clearLogButtonIconLayer = CALayer()
    private let headerLayer = CALayer()
    private let headerBorderLayer = CALayer()
    private let tableLayer = CALayer()
    private let rowsClipLayer = CALayer()
    private let scrollbarTrackLayer = CALayer()
    private let scrollbarThumbLayer = CALayer()
    private let processTimelineLayer = CALayer()
    private let processTimelineDividerLayer = CALayer()
    private let processTimelineRowsClipLayer = CALayer()
    private let processTimelineEventDotLayers: [CAShapeLayer] = [
        CAShapeLayer(),
        CAShapeLayer(),
        CAShapeLayer(),
        CAShapeLayer()
    ]
    private let processTimelineHoveredDotLayer = CAShapeLayer()
    private let processTimelineEmptyLayer = CATextLayer()
    private let processTimelineScrollbarTrackLayer = CALayer()
    private let processTimelineScrollbarThumbLayer = CALayer()
    private let filterPillLayer = CALayer()
    private let filterPillTextLayer = CATextLayer()
    private let filterPanelLayer = CALayer()
    private var filterRowLayers: [CALayer] = []
    private var filterColumnLayers: [CATextLayer] = []
    private var filterOperationLayers: [CATextLayer] = []
    private var filterValueLayers: [CATextLayer] = []
    private var filterRemoveLayers: [CATextLayer] = []
    private let filterSelectionLayer = CALayer()
    private let filterCaretLayer = CALayer()
    private let filterAddLayer = CATextLayer()
    private let machineUnsupportedOverlayLayer = CALayer()
    private var headerTextLayers: [CATextLayer] = []
    private var headerSeparatorLayers: [CALayer] = []
    private var rowLayers: [RowLayers] = []
    private var timelineRowLayers: [TimelineRowLayers] = []

    private var didRegisterLayer = false
    private var currentSize = CGSize(width: 960, height: 640)
    private var apiEndpoint: URL?
    private var processTimelineEndpoint: URL?
    private var eventPositionEndpoint: URL?
    private var captureEndpoint: URL?
    private var clearLogEndpoint: URL?
    private var urlSession: URLSession?
    private var pollTimer: Timer?
    private var inFlight = false
    private var pendingFetchAfterInFlight = false
    private var logGeneration = 0
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
    private var pendingFilterContextMenuID: UUID?
    private var pendingCellContextMenuID: UUID?
    private var pendingCellFilterContext: CellFilterContext?
    private var selectedTableCell: TableCellSelection?
    private var isCapturePaused = false
    private var capturePauseReason: CapturePauseReason = .none
    private var captureStorageStatus: CaptureStatus?
    private var machineUnsupportedPanelFrame = CGRect.zero
    private var machineUnsupportedTextLines: [MachineUnsupportedTextLine] = []
    private var machineUnsupportedSelectionAnchor: Int?
    private var machineUnsupportedSelectionFocus: Int?
    private var isSelectingMachineUnsupportedText = false
    private var machineUnsupportedContextMenuIDs = Set<UUID>()
    private var processTimelineInFlight = false
    private var pendingProcessTimelineFetchAfterInFlight = false
    private var lastProcessTimelineRequestedEventCount: UInt64 = 0
    private var lastProcessTimelineRequestedFilterKey = ""
    private var inFlightProcessTimelineFilterKey = ""
    private var lastProcessTimelineRequestedStart = -1
    private var lastProcessTimelineRequestedCount = -1
    private var inFlightProcessTimelineStart = 0
    private var processTimelineHasLoaded = false
    private var processTimelineResponse: ProcessTimelineResponse?
    private var processTimelineTotalRows = 0
    private var processTimelinePageStart = 0
    private var processTimelineRows: [TimelineProcessRow] = []
    private var processTimelineDotsByPID: [Int: [TimelineEventDot]] = [:]
    private var hoveredProcessTimelineDot: TimelineEventDotHit?
    private var processTimelineScrollOffset: CGFloat = 0
    private var isDraggingProcessTimelineScrollbar = false
    private var processTimelineScrollbarDragOffset: CGFloat = 0

    private let toolbarHeight: CGFloat = 58
    private let headerHeight: CGFloat = 30
    private let rowHeight: CGFloat = 26
    private let processTimelineRowHeight: CGFloat = 22
    private let processTimelineMinHeight: CGFloat = 132
    private let processTimelineMaxHeight: CGFloat = 220
    private let processTimelineNameWidth: CGFloat = 230
    private let processTimelinePIDWidth: CGFloat = 66
    private let processTimelineEventsWidth: CGFloat = 58
    private let horizontalInset: CGFloat = 18
    private let scrollbarWidth: CGFloat = 9
    private let scrollbarTrailingInset: CGFloat = 4
    private let scrollbarHitSlop: CGFloat = 5
    private let scrollbarVerticalDividerPadding: CGFloat = 3
    private let overscanScreens: CGFloat = 2
    private let renderedRowOverscan: Int = 8
    private let maxPrefetchRows = 512
    private let minPrefetchRows = 120
    private let processTimelineRenderedRowOverscan = 8
    private let processTimelineMinPrefetchRows = 48
    private let processTimelineMaxPrefetchRows = 160
    private let filterPillSize = CGSize(width: 260, height: 28)
    private let pauseButtonSize = CGSize(width: 28, height: 28)
    private let clearLogButtonSize = CGSize(width: 28, height: 28)
    private let toolbarButtonIconInset: CGFloat = 2
    private let toolbarButtonSymbolPointSize: CGFloat = 22
    private let filterPanelSize = CGSize(width: 460, height: 238)
    private let filterValueFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private let filterCaretWidth: CGFloat = 1
    private let filterCaretBlinkAnimationKey = "filterCaretBlink"
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
            outerframeHost.setTitle("Firehose")
            outerframeHost.setIcon(.bundleResource(path: "Contents/Resources/app-icon.png"))
            appearance = arguments.appearance ?? NSAppearance.currentDrawing()
            currentSize = arguments.contentSize ?? currentSize
            configureNetworking()
            configureLayersIfNeeded()
            updateLayout()
            updateColors()
            registerRootLayerIfNeeded()
            updateTextInputState()
            startPolling()
            fetchCaptureStatus()
            fetchVisibleWindow(force: true)
            fetchProcessTimeline(force: true)

        case .resizeContent(let size):
            currentSize = size
            resetScrollPrediction()
            clampScrollOffset()
            clampProcessTimelineScrollOffset()
            updateLayout()
            fetchVisibleWindow(force: true)
            fetchProcessTimeline(force: false)

        case .systemAppearanceUpdate(let appearance):
            self.appearance = appearance
            updateColors()

        case .scrollWheelEvent(let point, let delta, _, _, _, let hasPreciseScrollingDeltas):
            guard !isMachineUnsupported else { return }
            let multiplier = hasPreciseScrollingDeltas ? CGFloat(1) : rowHeight
            if processTimelineRowsClipLayer.frame.contains(processTimelineLayer.convert(point, from: rootLayer)) {
                processTimelineScrollOffset -= delta.y * multiplier
                clampProcessTimelineScrollOffset()
                updateLayout()
                updateHoveredProcessTimelineDot(at: point)
                fetchProcessTimeline(force: false)
                return
            }
            guard rowsClipLayer.frame.contains(tableLayer.convert(point, from: rootLayer)) else { return }
            scrollOffset -= delta.y * multiplier
            clampScrollOffset()
            recordScrollSample()
            updateLayout()
            fetchVisibleWindow(force: false)

        case .mouseDown(let point, let modifierFlags, let clickCount):
            if isMachineUnsupported {
                if modifierFlags.contains(.control) {
                    showMachineUnsupportedContextMenu(at: point)
                    return
                }
                handleMachineUnsupportedMouseDown(at: point, clickCount: clickCount)
                return
            }
            if modifierFlags.contains(.control) {
                if !handleFilterContextMenu(at: point) {
                    handleCellContextMenu(at: point)
                }
                return
            }
            if !handleToolbarMouseDown(at: point),
               !handleFilterMouseDown(at: point, modifierFlags: modifierFlags, clickCount: clickCount) {
                if !handleProcessTimelineScrollbarMouseDown(at: point),
                   !handleProcessTimelineMouseDown(at: point),
                   !handleTableCellMouseDown(at: point) {
                    _ = handleScrollbarMouseDown(at: point)
                }
            }

        case .mouseDragged(let point, _):
            if isMachineUnsupported {
                handleMachineUnsupportedMouseDragged(at: point)
                return
            }
            if !handleProcessTimelineScrollbarMouseDragged(to: point) {
                _ = handleScrollbarMouseDragged(to: point)
            }
            updateHoveredProcessTimelineDot(at: point)

        case .mouseUp(let point, _):
            if isMachineUnsupported {
                handleMachineUnsupportedMouseUp(at: point)
                return
            }
            if !handleProcessTimelineScrollbarMouseUp(at: point) {
                _ = handleScrollbarMouseUp(at: point)
            }

        case .mouseMoved(let point, _):
            if isMachineUnsupported {
                outerframeHost.setCursor(machineUnsupportedCharacterIndex(at: point) == nil ? .arrow : .iBeam)
                return
            }
            updateHoveredProcessTimelineDot(at: point)

        case .rightMouseDown(let point, _, _):
            if isMachineUnsupported {
                showMachineUnsupportedContextMenu(at: point)
                return
            }
            if !handleFilterContextMenu(at: point) {
                handleCellContextMenu(at: point)
            }

        case .contextMenuItemSelected(let menuID, let itemID):
            if isMachineUnsupported {
                handleMachineUnsupportedContextMenuSelection(menuID: menuID, itemID: itemID)
                return
            }
            handleContextMenuSelection(menuID: menuID, itemID: itemID)

        case .keyDown(let keyCode, let characters, let charactersIgnoringModifiers, let modifierFlags, _):
            if isMachineUnsupported {
                handleMachineUnsupportedKeyDown(charactersIgnoringModifiers: charactersIgnoringModifiers,
                                                modifierFlags: modifierFlags)
                return
            }
            if !handleFilterKeyDown(keyCode: keyCode, characters: characters) {
                handleKeyDown(keyCode: keyCode)
            }

        case .textInput(let text, let hasReplacementRange, let replacementLocation, let replacementLength):
            guard !isMachineUnsupported else { return }
            _ = handleFilterTextInput(text,
                                      hasReplacementRange: hasReplacementRange,
                                      replacementLocation: replacementLocation,
                                      replacementLength: replacementLength)

        case .setMarkedText:
            break

        case .unmarkText:
            break

        case .textCommand(let command):
            guard !isMachineUnsupported else { return }
            _ = handleFilterTextCommand(command)

        case .setCursorPosition(let fieldID, let position, let modifySelection):
            guard !isMachineUnsupported else { return }
            guard fieldID == Self.filterFieldID else { return }
            setFilterPanelExpanded(true)
            filterInputController.setCursorPosition(Int(position), modifySelection: modifySelection)

        case .textInputFocus(let fieldID, let hasFocus):
            guard !isMachineUnsupported else { return }
            guard fieldID == Self.filterFieldID else { return }
            if hasFocus {
                setFilterPanelExpanded(true)
                syncFilterInputToActiveClause(moveCursorToEnd: false)
            } else {
                setFilterPanelExpanded(false)
            }

        case .selectionToPasteboardCopyRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: pasteboardItemsForCopy())

        case .selectionToPasteboardCutRequest(let requestID):
            let items = pasteboardItemsForCopy()
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: items)
            if filterInputController.isFocused, !items.isEmpty {
                filterInputController.insertText("")
            }

        case .editCommandValidationRequest(let requestID, let commands):
            outerframeHost.sendEditCommandValidationResponse(
                requestID: requestID,
                enabledCommands: enabledEditCommands(in: commands)
            )

        case .pasteboardContentPasted(let items):
            handlePasteboardItemsForPaste(items)

        case .pasteboardAccessResponse:
            break

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
            processTimelineEndpoint = URL(string: "/api/processes", relativeTo: base)?.absoluteURL
            eventPositionEndpoint = URL(string: "/api/event-position", relativeTo: base)?.absoluteURL
            captureEndpoint = URL(string: "/api/capture", relativeTo: base)?.absoluteURL
            clearLogEndpoint = URL(string: "/api/clear", relativeTo: base)?.absoluteURL
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
                guard let self else { return }
                self.fetchVisibleWindow(force: true)
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
        rootLayer.addSublayer(processTimelineLayer)
        rootLayer.addSublayer(toolbarLayer)
        rootLayer.addSublayer(headerLayer)
        rootLayer.addSublayer(headerBorderLayer)
        toolbarLayer.addSublayer(statusLayer)
        toolbarLayer.addSublayer(pauseButtonLayer)
        pauseButtonLayer.addSublayer(pauseButtonIconLayer)
        toolbarLayer.addSublayer(clearLogButtonLayer)
        clearLogButtonLayer.addSublayer(clearLogButtonIconLayer)
        tableLayer.addSublayer(rowsClipLayer)
        tableLayer.addSublayer(scrollbarTrackLayer)
        scrollbarTrackLayer.addSublayer(scrollbarThumbLayer)
        processTimelineLayer.addSublayer(processTimelineDividerLayer)
        processTimelineLayer.addSublayer(processTimelineRowsClipLayer)
        processTimelineLayer.addSublayer(processTimelineScrollbarTrackLayer)
        for dotLayer in processTimelineEventDotLayers {
            dotLayer.zPosition = 5
            dotLayer.contentsScale = 2
            processTimelineRowsClipLayer.addSublayer(dotLayer)
        }
        processTimelineHoveredDotLayer.zPosition = 6
        processTimelineHoveredDotLayer.contentsScale = 2
        processTimelineRowsClipLayer.addSublayer(processTimelineHoveredDotLayer)
        processTimelineRowsClipLayer.addSublayer(processTimelineEmptyLayer)
        processTimelineScrollbarTrackLayer.addSublayer(processTimelineScrollbarThumbLayer)
        rootLayer.addSublayer(filterPillLayer)
        rootLayer.addSublayer(filterPanelLayer)
        rootLayer.addSublayer(machineUnsupportedOverlayLayer)
        filterPillLayer.addSublayer(filterPillTextLayer)

        statusLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLayer.fontSize = 12
        statusLayer.contentsScale = 2
        statusLayer.truncationMode = .end

        pauseButtonLayer.cornerRadius = pauseButtonSize.height / 2
        pauseButtonLayer.masksToBounds = true
        pauseButtonIconLayer.contentsGravity = .resizeAspect
        pauseButtonIconLayer.contentsScale = 2
        clearLogButtonLayer.cornerRadius = clearLogButtonSize.height / 2
        clearLogButtonLayer.masksToBounds = true
        clearLogButtonIconLayer.contentsGravity = .resizeAspect
        clearLogButtonIconLayer.contentsScale = 2

        processTimelineEmptyLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        processTimelineEmptyLayer.fontSize = 12
        processTimelineEmptyLayer.contentsScale = 2
        processTimelineEmptyLayer.alignmentMode = .center
        processTimelineEmptyLayer.string = "No process events yet"

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
        machineUnsupportedOverlayLayer.zPosition = 1_000
        machineUnsupportedOverlayLayer.isHidden = true

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
        filterCaretLayer.backgroundColor = NSColor.textColor.cgColor
        filterCaretLayer.isHidden = true
        filterPanelLayer.addSublayer(filterCaretLayer)

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
        processTimelineRowsClipLayer.masksToBounds = true
        processTimelineScrollbarTrackLayer.cornerRadius = scrollbarWidth / 2
        processTimelineScrollbarThumbLayer.cornerRadius = scrollbarWidth / 2
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

    private func makeTimelineRowLayers() -> TimelineRowLayers {
        let container = CALayer()
        let background = CALayer()
        let name = makeTextLayer(size: 12, weight: .regular)
        let pid = makeTextLayer(size: 11, weight: .regular, alignment: .right)
        let events = makeTextLayer(size: 11, weight: .regular, alignment: .right)
        let barTrack = CALayer()
        let bar = CALayer()

        background.cornerRadius = 4
        barTrack.cornerRadius = 2
        bar.cornerRadius = 2
        container.addSublayer(background)
        container.addSublayer(name)
        container.addSublayer(pid)
        container.addSublayer(events)
        container.addSublayer(barTrack)
        container.addSublayer(bar)
        processTimelineRowsClipLayer.addSublayer(container)

        let row = TimelineRowLayers(container: container,
                                    background: background,
                                    name: name,
                                    pid: pid,
                                    events: events,
                                    barTrack: barTrack,
                                    bar: bar)
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

            let contentHeight = max(height - toolbarHeight, 1)
            let timelineHeight = processTimelineHeight(for: contentHeight)
            let tableHeight = max(contentHeight - timelineHeight, 1)
            processTimelineLayer.frame = CGRect(x: 0, y: 0, width: width, height: timelineHeight)
            tableLayer.frame = CGRect(x: 0, y: timelineHeight, width: width, height: tableHeight)
            let scrollbarX = width - scrollbarTrailingInset - scrollbarWidth
            headerLayer.frame = CGRect(x: horizontalInset,
                                       y: timelineHeight + tableHeight - headerHeight,
                                       width: max(scrollbarX - horizontalInset - 8, 1),
                                       height: headerHeight)
            let borderHeight = horizontalDividerHeight()
            headerBorderLayer.frame = CGRect(x: 0,
                                             y: headerLayer.frame.minY - borderHeight,
                                             width: width,
                                             height: borderHeight)
            rowsClipLayer.frame = CGRect(x: horizontalInset,
                                         y: 0,
                                         width: max(scrollbarX - horizontalInset - 8, 1),
                                         height: max(tableHeight - headerHeight, 1))
            let tableScrollbarYOffset = min(scrollbarVerticalDividerPadding,
                                             max(rowsClipLayer.bounds.height / 2, 0))
            scrollbarTrackLayer.frame = CGRect(x: scrollbarX,
                                               y: tableScrollbarYOffset,
                                               width: scrollbarWidth,
                                               height: max(rowsClipLayer.bounds.height - tableScrollbarYOffset * 2, 1))

            layoutColumnHeaders()
            updateRows()
            layoutRows()
            layoutScrollbar()
            layoutProcessTimeline()
            layoutFilterUI()
            layoutToolbarStatus()
            updateStatusText()
            renderMachineUnsupportedOverlay()
        }
        notifyAccessibilityLayoutChanged()
    }

    private func processTimelineHeight(for contentHeight: CGFloat) -> CGFloat {
        guard contentHeight > 220 else {
            return min(max(contentHeight * 0.36, 88), max(contentHeight - 96, 64))
        }
        return min(max(floor(contentHeight * 0.30), processTimelineMinHeight), processTimelineMaxHeight)
    }

    private func horizontalDividerHeight() -> CGFloat {
        max(1 / max(headerLayer.contentsScale, 1), 0.5)
    }

    private func layoutToolbarStatus() {
        let statusMaxX = max(pauseButtonLayer.frame.minX - 16, horizontalInset + 80)
        let statusWidth = max(statusMaxX - horizontalInset, 1)
        statusLayer.frame = CGRect(x: horizontalInset,
                                   y: 21,
                                   width: statusWidth,
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

        clearLogButtonLayer.frame = CGRect(x: max(pillX - clearLogButtonSize.width - 8, horizontalInset),
                                           y: (toolbarHeight - clearLogButtonSize.height) / 2,
                                           width: clearLogButtonSize.width,
                                           height: clearLogButtonSize.height)
        clearLogButtonIconLayer.frame = clearLogButtonLayer.bounds.insetBy(dx: toolbarButtonIconInset,
                                                                           dy: toolbarButtonIconInset)

        pauseButtonLayer.frame = CGRect(x: max(clearLogButtonLayer.frame.minX - pauseButtonSize.width - 6, horizontalInset),
                                        y: (toolbarHeight - pauseButtonSize.height) / 2,
                                        width: pauseButtonSize.width,
                                        height: pauseButtonSize.height)
        pauseButtonIconLayer.frame = pauseButtonLayer.bounds.insetBy(dx: toolbarButtonIconInset,
                                                                     dy: toolbarButtonIconInset)

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
        let renderedStart = renderedRowRange().start
        for (index, row) in rowLayers.enumerated() {
            let globalIndex = renderedStart + index
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
        let trackHeight = scrollbarTrackLayer.bounds.height
        let contentHeight = CGFloat(totalRows) * rowHeight
        let maxOffset = max(contentHeight - viewportHeight, 0)
        scrollbarTrackLayer.isHidden = maxOffset <= 0
        if maxOffset <= 0 {
            scrollbarThumbLayer.frame = CGRect(x: 0, y: 0, width: scrollbarWidth, height: trackHeight)
            return
        }

        let thumbHeight = max((viewportHeight / contentHeight) * trackHeight, 32)
        let travel = max(trackHeight - thumbHeight, 0)
        let y = trackHeight - thumbHeight - (scrollOffset / maxOffset) * travel
        scrollbarThumbLayer.frame = CGRect(x: 0, y: y, width: scrollbarWidth, height: thumbHeight)
    }

    private func layoutProcessTimeline() {
        let bounds = processTimelineLayer.bounds
        let scrollbarX = bounds.width - scrollbarTrailingInset - scrollbarWidth
        let dividerHeight = horizontalDividerHeight()
        processTimelineDividerLayer.frame = CGRect(x: 0,
                                                   y: max(bounds.height - dividerHeight, 0),
                                                   width: bounds.width,
                                                   height: dividerHeight)
        processTimelineRowsClipLayer.frame = CGRect(x: horizontalInset,
                                                    y: 0,
                                                    width: max(scrollbarX - horizontalInset - 8, 1),
                                                    height: max(bounds.height - dividerHeight, 1))
        let timelineScrollbarTopPadding = min(scrollbarVerticalDividerPadding,
                                              max(processTimelineRowsClipLayer.bounds.height / 2, 0))
        processTimelineScrollbarTrackLayer.frame = CGRect(x: scrollbarX,
                                                          y: 0,
                                                          width: scrollbarWidth,
                                                          height: max(processTimelineRowsClipLayer.bounds.height - timelineScrollbarTopPadding, 1))
        updateTimelineRowLayerCount()
        layoutTimelineRows()
        layoutProcessTimelineScrollbar()
    }

    private func layoutTimelineRows() {
        let timelineWidth = max(processTimelineRowsClipLayer.bounds.width - processTimelineNameWidth - processTimelinePIDWidth - processTimelineEventsWidth - 24, 24)
        let timelineX = processTimelineNameWidth + processTimelinePIDWidth + processTimelineEventsWidth + 18
        let visibleStart = processTimelineVisibleStartIndex()
        let startTime = processTimelineResponse?.captureStart ?? 0
        let endTime = max(processTimelineResponse?.captureEnd ?? startTime, startTime + 0.001)
        let duration = max(endTime - startTime, 0.001)
        let visibleTimelineRowCount = min(timelineRowLayers.count, max(processTimelineTotalRows - visibleStart, 0))

        for (layerIndex, row) in timelineRowLayers.enumerated() {
            let processIndex = visibleStart + layerIndex
            guard processIndex < processTimelineTotalRows,
                  let item = processTimelineRow(forGlobalIndex: processIndex) else {
                row.container.isHidden = true
                continue
            }

            let process = item.process
            let y = processTimelineRowsClipLayer.bounds.height - CGFloat(layerIndex + 1) * processTimelineRowHeight
            row.container.isHidden = false
            row.container.frame = CGRect(x: 0,
                                         y: y,
                                         width: processTimelineRowsClipLayer.bounds.width,
                                         height: processTimelineRowHeight)
            row.background.frame = row.container.bounds.insetBy(dx: 0, dy: 1)
            let indent = min(CGFloat(item.level) * 12, 72)
            row.name.frame = CGRect(x: indent + 6, y: 4, width: max(processTimelineNameWidth - indent - 8, 1), height: 15)
            row.pid.frame = CGRect(x: processTimelineNameWidth,
                                   y: 4,
                                   width: processTimelinePIDWidth,
                                   height: 15)
            row.events.frame = CGRect(x: processTimelineNameWidth + processTimelinePIDWidth + 6,
                                      y: 4,
                                      width: processTimelineEventsWidth,
                                      height: 15)
            row.barTrack.frame = CGRect(x: timelineX,
                                        y: 9,
                                        width: timelineWidth,
                                        height: 4)

            let rawStartX = CGFloat((process.startTimestamp - startTime) / duration) * timelineWidth
            let rawEndX = CGFloat((process.endTimestamp - startTime) / duration) * timelineWidth
            let startX = min(max(rawStartX, 0), timelineWidth)
            let endX = min(max(rawEndX, startX), timelineWidth)
            let barWidth = max(endX - startX, process.isRunning ? 3 : 4)
            row.bar.frame = CGRect(x: timelineX + startX,
                                   y: 7,
                                   width: min(barWidth, max(timelineWidth - startX, 2)),
                                   height: 8)
            row.name.string = process.process.isEmpty ? "pid-\(process.pid)" : process.process
            row.pid.string = String(process.pid)
            row.events.string = formatCompactCount(process.eventCount)
            row.background.opacity = processIndex % 2 == 0 ? 0.28 : 0
            appearance?.performAsCurrentDrawingAppearance {
                row.bar.backgroundColor = NSColor.systemGreen
                    .withAlphaComponent(process.openAtStart ? 0.72 : 0.88)
                    .cgColor
            }
        }
        layoutTimelineEventDots(timelineX: timelineX,
                                timelineWidth: timelineWidth,
                                visibleRowCount: visibleTimelineRowCount)
        layoutHoveredProcessTimelineDot()

        processTimelineEmptyLayer.isHidden = processTimelineTotalRows > 0 || processTimelineInFlight || !processTimelineHasLoaded
        processTimelineEmptyLayer.frame = processTimelineRowsClipLayer.bounds.insetBy(dx: 16, dy: max(processTimelineRowsClipLayer.bounds.height / 2 - 10, 0))
    }

    private func layoutTimelineEventDots(timelineX: CGFloat,
                                         timelineWidth: CGFloat,
                                         visibleRowCount: Int) {
        guard let response = processTimelineResponse,
              response.eventDotBucketCount > 0,
              response.eventDotMaxCount > 0,
              !response.eventDots.isEmpty,
              visibleRowCount > 0,
              timelineWidth > 0 else {
            for layer in processTimelineEventDotLayers {
                layer.path = nil
            }
            hoveredProcessTimelineDot = nil
            processTimelineHoveredDotLayer.path = nil
            return
        }

        let paths = processTimelineEventDotLayers.map { _ in CGMutablePath() }
        let maxCount = max(response.eventDotMaxCount, 1)
        let radius: CGFloat = 1.9
        let startTime = response.captureStart
        let endTime = max(response.captureEnd, startTime + 0.001)
        let duration = max(endTime - startTime, 0.001)

        let visibleStart = processTimelineVisibleStartIndex()
        var visibleRowByPID: [Int: Int] = [:]
        visibleRowByPID.reserveCapacity(visibleRowCount)
        for layerIndex in 0..<visibleRowCount {
            let processIndex = visibleStart + layerIndex
            guard let item = processTimelineRow(forGlobalIndex: processIndex) else { continue }
            visibleRowByPID[item.process.pid] = layerIndex
        }

        for dot in response.eventDots where dot.count > 0 {
            guard dot.bucketIndex >= 0 && dot.bucketIndex < response.eventDotBucketCount,
                  let layerIndex = visibleRowByPID[dot.pid] else { continue }
            let normalized = CGFloat((dot.timestamp - startTime) / duration)
            let x = timelineX + min(max(normalized, 0), 1) * timelineWidth
            let cappedCount = min(max(dot.count, 1), maxCount)
            let band = min(max((cappedCount - 1) * processTimelineEventDotLayers.count / maxCount, 0),
                           processTimelineEventDotLayers.count - 1)
            let rowCenterY = processTimelineRowsClipLayer.bounds.height -
                CGFloat(layerIndex + 1) * processTimelineRowHeight +
                processTimelineRowHeight / 2
            paths[band].addEllipse(in: CGRect(x: x - radius,
                                              y: rowCenterY - radius,
                                              width: radius * 2,
                                              height: radius * 2))
        }

        for (index, layer) in processTimelineEventDotLayers.enumerated() {
            layer.frame = processTimelineRowsClipLayer.bounds
            layer.path = paths[index]
        }
    }

    private func nearestProcessTimelineDot(at point: CGPoint) -> TimelineEventDotHit? {
        guard let response = processTimelineResponse,
              response.eventDotBucketCount > 0,
              !processTimelineDotsByPID.isEmpty else {
            return nil
        }

        let timelinePoint = processTimelineRowsClipLayer.convert(point, from: rootLayer)
        guard processTimelineRowsClipLayer.bounds.contains(timelinePoint) else {
            return nil
        }

        let timelineWidth = max(processTimelineRowsClipLayer.bounds.width - processTimelineNameWidth - processTimelinePIDWidth - processTimelineEventsWidth - 24, 24)
        let timelineX = processTimelineNameWidth + processTimelinePIDWidth + processTimelineEventsWidth + 18
        guard timelinePoint.x >= timelineX - 12,
              timelinePoint.x <= timelineX + timelineWidth + 12 else {
            return nil
        }

        let visibleStart = processTimelineVisibleStartIndex()
        let visibleCount = min(timelineRowLayers.count, max(processTimelineTotalRows - visibleStart, 0))
        guard visibleCount > 0 else { return nil }

        let startTime = response.captureStart
        let endTime = max(response.captureEnd, startTime + 0.001)
        let duration = max(endTime - startTime, 0.001)
        var bestHit: TimelineEventDotHit?
        var bestDistanceSquared = CGFloat.greatestFiniteMagnitude
        let maxDistance: CGFloat = 14
        let maxDistanceSquared = maxDistance * maxDistance

        for layerIndex in 0..<visibleCount {
            let processIndex = visibleStart + layerIndex
            guard let item = processTimelineRow(forGlobalIndex: processIndex) else { continue }
            let pid = item.process.pid
            guard let dots = processTimelineDotsByPID[pid] else { continue }
            let rowCenterY = processTimelineRowsClipLayer.bounds.height -
                CGFloat(layerIndex + 1) * processTimelineRowHeight +
                processTimelineRowHeight / 2

            for dot in dots where dot.count > 0 {
                guard dot.bucketIndex >= 0 && dot.bucketIndex < response.eventDotBucketCount else { continue }
                let normalized = CGFloat((dot.timestamp - startTime) / duration)
                let center = CGPoint(x: timelineX + min(max(normalized, 0), 1) * timelineWidth,
                                     y: rowCenterY)
                let dx = center.x - timelinePoint.x
                let dy = center.y - timelinePoint.y
                let distanceSquared = dx * dx + dy * dy
                guard distanceSquared < bestDistanceSquared else { continue }

                bestDistanceSquared = distanceSquared
                bestHit = TimelineEventDotHit(pid: pid,
                                              bucketIndex: dot.bucketIndex,
                                              count: dot.count,
                                              timestamp: dot.timestamp,
                                              filteredIndex: dot.filteredIndex,
                                              center: center)
            }
        }

        guard bestDistanceSquared <= maxDistanceSquared else { return nil }
        return bestHit
    }

    private func processTimelineDotCenter(pid: Int, bucketIndex: Int, timestamp: Double) -> CGPoint? {
        guard let response = processTimelineResponse,
              response.eventDotBucketCount > 0,
              bucketIndex >= 0,
              bucketIndex < response.eventDotBucketCount else {
            return nil
        }

        let timelineWidth = max(processTimelineRowsClipLayer.bounds.width - processTimelineNameWidth - processTimelinePIDWidth - processTimelineEventsWidth - 24, 24)
        let timelineX = processTimelineNameWidth + processTimelinePIDWidth + processTimelineEventsWidth + 18
        let visibleStart = processTimelineVisibleStartIndex()
        let visibleCount = min(timelineRowLayers.count, max(processTimelineTotalRows - visibleStart, 0))
        let startTime = response.captureStart
        let endTime = max(response.captureEnd, startTime + 0.001)
        let duration = max(endTime - startTime, 0.001)

        for layerIndex in 0..<visibleCount {
            let processIndex = visibleStart + layerIndex
            guard let item = processTimelineRow(forGlobalIndex: processIndex),
                  item.process.pid == pid else { continue }

            let normalized = CGFloat((timestamp - startTime) / duration)
            let rowCenterY = processTimelineRowsClipLayer.bounds.height -
                CGFloat(layerIndex + 1) * processTimelineRowHeight +
                processTimelineRowHeight / 2
            return CGPoint(x: timelineX + min(max(normalized, 0), 1) * timelineWidth,
                           y: rowCenterY)
        }
        return nil
    }

    private func updateHoveredProcessTimelineDot(at point: CGPoint) {
        hoveredProcessTimelineDot = nearestProcessTimelineDot(at: point)
        layoutHoveredProcessTimelineDot()
    }

    private func clickedProcessTimelineDot(at point: CGPoint) -> TimelineEventDotHit? {
        let timelinePoint = processTimelineRowsClipLayer.convert(point, from: rootLayer)
        if let hoveredProcessTimelineDot,
           let center = processTimelineDotCenter(pid: hoveredProcessTimelineDot.pid,
                                                 bucketIndex: hoveredProcessTimelineDot.bucketIndex,
                                                 timestamp: hoveredProcessTimelineDot.timestamp) {
            let dx = center.x - timelinePoint.x
            let dy = center.y - timelinePoint.y
            if dx * dx + dy * dy <= 18 * 18 {
                return TimelineEventDotHit(pid: hoveredProcessTimelineDot.pid,
                                           bucketIndex: hoveredProcessTimelineDot.bucketIndex,
                                           count: hoveredProcessTimelineDot.count,
                                           timestamp: hoveredProcessTimelineDot.timestamp,
                                           filteredIndex: hoveredProcessTimelineDot.filteredIndex,
                                           center: center)
            }
        }
        return nearestProcessTimelineDot(at: point)
    }

    private func layoutHoveredProcessTimelineDot() {
        guard let hoveredProcessTimelineDot,
              let center = processTimelineDotCenter(pid: hoveredProcessTimelineDot.pid,
                                                    bucketIndex: hoveredProcessTimelineDot.bucketIndex,
                                                    timestamp: hoveredProcessTimelineDot.timestamp) else {
            processTimelineHoveredDotLayer.path = nil
            return
        }

        let radius = CGFloat(min(max(4 + hoveredProcessTimelineDot.count / 4, 5), 8))
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - radius,
                                   y: center.y - radius,
                                   width: radius * 2,
                                   height: radius * 2))
        processTimelineHoveredDotLayer.frame = processTimelineRowsClipLayer.bounds
        processTimelineHoveredDotLayer.path = path
    }

    private func layoutProcessTimelineScrollbar() {
        let viewportHeight = processTimelineRowsClipLayer.bounds.height
        let trackHeight = processTimelineScrollbarTrackLayer.bounds.height
        let contentHeight = CGFloat(processTimelineTotalRows) * processTimelineRowHeight
        let maxOffset = max(contentHeight - viewportHeight, 0)
        processTimelineScrollbarTrackLayer.isHidden = maxOffset <= 0
        if maxOffset <= 0 {
            processTimelineScrollbarThumbLayer.frame = CGRect(x: 0, y: 0, width: scrollbarWidth, height: trackHeight)
            return
        }

        let thumbHeight = max((viewportHeight / contentHeight) * trackHeight, 28)
        let travel = max(trackHeight - thumbHeight, 0)
        let y = trackHeight - thumbHeight - (processTimelineScrollOffset / maxOffset) * travel
        processTimelineScrollbarThumbLayer.frame = CGRect(x: 0, y: y, width: scrollbarWidth, height: thumbHeight)
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

    private func handleProcessTimelineScrollbarMouseDown(at point: CGPoint) -> Bool {
        guard !processTimelineScrollbarTrackLayer.isHidden,
              maxProcessTimelineScrollOffset() > 0 else {
            return false
        }

        let trackPoint = processTimelineScrollbarTrackLayer.convert(point, from: rootLayer)
        let hitBounds = processTimelineScrollbarTrackLayer.bounds.insetBy(dx: -scrollbarHitSlop, dy: 0)
        guard hitBounds.contains(trackPoint) else {
            return false
        }

        let thumbHitFrame = processTimelineScrollbarThumbLayer.frame.insetBy(dx: -scrollbarHitSlop, dy: 0)
        if thumbHitFrame.contains(trackPoint) {
            isDraggingProcessTimelineScrollbar = true
            processTimelineScrollbarDragOffset = min(max(trackPoint.y - processTimelineScrollbarThumbLayer.frame.minY, 0),
                                                     processTimelineScrollbarThumbLayer.frame.height)
            return true
        }

        let targetThumbY = trackPoint.y - processTimelineScrollbarThumbLayer.bounds.height * 0.5
        setProcessTimelineScrollOffsetForScrollbarThumbY(targetThumbY)
        isDraggingProcessTimelineScrollbar = true
        processTimelineScrollbarDragOffset = processTimelineScrollbarThumbLayer.bounds.height * 0.5
        return true
    }

    private func handleProcessTimelineScrollbarMouseDragged(to point: CGPoint) -> Bool {
        guard isDraggingProcessTimelineScrollbar else { return false }
        let trackPoint = processTimelineScrollbarTrackLayer.convert(point, from: rootLayer)
        setProcessTimelineScrollOffsetForScrollbarThumbY(trackPoint.y - processTimelineScrollbarDragOffset)
        return true
    }

    private func handleProcessTimelineScrollbarMouseUp(at point: CGPoint) -> Bool {
        let wasDragging = isDraggingProcessTimelineScrollbar
        isDraggingProcessTimelineScrollbar = false
        processTimelineScrollbarDragOffset = 0
        return wasDragging && processTimelineScrollbarTrackLayer.bounds.insetBy(dx: -scrollbarHitSlop, dy: 0)
            .contains(processTimelineScrollbarTrackLayer.convert(point, from: rootLayer))
    }

    private func handleProcessTimelineMouseDown(at point: CGPoint) -> Bool {
        let timelinePoint = processTimelineRowsClipLayer.convert(point, from: rootLayer)
        guard processTimelineRowsClipLayer.bounds.contains(timelinePoint) else {
            return false
        }

        if let dot = clickedProcessTimelineDot(at: point) {
            hoveredProcessTimelineDot = dot
            layoutHoveredProcessTimelineDot()
            if let filteredIndex = dot.filteredIndex {
                scrollToFilteredEventIndex(filteredIndex)
            } else {
                jumpToEvent(for: dot.pid,
                            nearTimestamp: dot.timestamp,
                            bucketIndex: dot.bucketIndex)
            }
            return true
        }

        let rowFromTop = Int(floor((processTimelineRowsClipLayer.bounds.height - timelinePoint.y) / processTimelineRowHeight))
        let processIndex = processTimelineVisibleStartIndex() + max(rowFromTop, 0)
        guard processIndex >= 0,
              processIndex < processTimelineTotalRows,
              let row = processTimelineRow(forGlobalIndex: processIndex) else {
            fetchProcessTimeline(force: false)
            return true
        }

        jumpToEvent(for: row.process.pid)
        return true
    }

    private func handleTableCellMouseDown(at point: CGPoint) -> Bool {
        guard let hit = tableCellHit(at: point),
              !hit.value.isEmpty else {
            selectedTableCell = nil
            updateTextInputState()
            return false
        }

        selectedTableCell = TableCellSelection(columnTitle: hit.columnTitle, value: hit.value)
        updateTextInputState()
        return true
    }

    private func handleToolbarMouseDown(at point: CGPoint) -> Bool {
        let toolbarPoint = toolbarLayer.convert(point, from: rootLayer)
        if pauseButtonLayer.frame.insetBy(dx: -4, dy: -4).contains(toolbarPoint) {
            setCapturePaused(!isCapturePaused)
            return true
        }
        if clearLogButtonLayer.frame.insetBy(dx: -4, dy: -4).contains(toolbarPoint) {
            clearLog()
            return true
        }
        return false
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

    private func setProcessTimelineScrollOffsetForScrollbarThumbY(_ thumbY: CGFloat) {
        let trackHeight = processTimelineScrollbarTrackLayer.bounds.height
        let thumbHeight = processTimelineScrollbarThumbLayer.bounds.height
        let travel = max(trackHeight - thumbHeight, 0)
        guard travel > 0 else { return }

        let clampedThumbY = min(max(thumbY, 0), travel)
        let normalizedFromTop = (travel - clampedThumbY) / travel
        processTimelineScrollOffset = normalizedFromTop * maxProcessTimelineScrollOffset()
        clampProcessTimelineScrollOffset()
        updateLayout()
        fetchProcessTimeline(force: false)
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
        guard let tableHit = tableCellHit(at: point),
              !tableHit.value.isEmpty else {
            return
        }

        selectedTableCell = TableCellSelection(columnTitle: tableHit.columnTitle, value: tableHit.value)
        updateTextInputState()

        let menuID = UUID()
        pendingCellContextMenuID = menuID
        let filterHit = cellFilterHit(at: point)
        if let filterHit, !filterHit.value.isEmpty {
            pendingCellFilterContext = CellFilterContext(menuID: menuID,
                                                         column: filterHit.column,
                                                         value: filterHit.value)
        } else {
            pendingCellFilterContext = nil
        }

        var menuItems: [OuterframeContextMenuItem] = []
        if let filterHit, !filterHit.value.isEmpty {
            let value = displayValue(filterHit.value, maxLength: 80)
            menuItems.append(OuterframeContextMenuItem(id: "include",
                                                       title: "Include \(filterHit.column.title) is \"\(value)\""))
            menuItems.append(OuterframeContextMenuItem(id: "exclude",
                                                       title: "Exclude \(filterHit.column.title) is \"\(value)\""))
            menuItems.append(OuterframeContextMenuItem(id: "copy-separator",
                                                       title: "",
                                                       kind: .separator,
                                                       isEnabled: false))
        }
        menuItems.append(OuterframeContextMenuItem(id: "copy",
                                                   title: "Copy",
                                                   action: .standardCopy))

        outerframeHost.showContextMenu(
            menuID: menuID,
            items: menuItems,
            at: point
        )
    }

    private func handleFilterContextMenu(at point: CGPoint) -> Bool {
        guard isFilterPanelExpanded,
              filterPanelLayer.frame.contains(point) else {
            return false
        }

        let panelPoint = filterPanelLayer.convert(point, from: rootLayer)
        for index in 0..<min(filterClauses.count, maxFilterClauseRows) {
            guard filterValueLayers[index].frame.insetBy(dx: -6, dy: -5).contains(panelPoint) ||
                    filterRowLayers[index].frame.contains(panelPoint) else {
                continue
            }

            activeFilterIndex = index
            syncFilterInputToActiveClause(moveCursorToEnd: false)
            if filterValueLayers[index].frame.insetBy(dx: -6, dy: -5).contains(panelPoint) {
                let characterIndex = characterIndexForFilterValue(panelPoint: panelPoint, rowIndex: index)
                if let range = filterInputController.selectionRange,
                   range.contains(characterIndex) {
                    // Preserve the existing selection for Copy/Cut and Services.
                } else {
                    filterInputController.setCursorPosition(characterIndex, modifySelection: false)
                }
            }
            updateFilterText()
            updateTextInputState()
            let selectedText = filterInputController.selectedTextContent() ?? ""
            var menuItems: [OuterframeContextMenuItem] = []
            if !selectedText.isEmpty {
                menuItems.append(OuterframeContextMenuItem(id: "lookup",
                                                           title: "Look Up \"\(displayValue(selectedText, maxLength: 80))\"",
                                                           action: .standardLookUp))
                menuItems.append(OuterframeContextMenuItem(id: "lookup-separator",
                                                           title: "",
                                                           kind: .separator,
                                                           isEnabled: false))
            }
            menuItems.append(OuterframeContextMenuItem(id: "cut",
                                                       title: "Cut",
                                                       action: .standardCut,
                                                       isEnabled: filterInputController.hasSelection))
            menuItems.append(OuterframeContextMenuItem(id: "copy",
                                                       title: "Copy",
                                                       action: .standardCopy,
                                                       isEnabled: filterInputController.hasSelection))
            menuItems.append(OuterframeContextMenuItem(id: "paste",
                                                       title: "Paste",
                                                       action: .standardPaste))
            if !selectedText.isEmpty {
                menuItems.append(OuterframeContextMenuItem(id: "services-separator",
                                                           title: "",
                                                           kind: .separator,
                                                           isEnabled: false))
                menuItems.append(OuterframeContextMenuItem(id: "services",
                                                           title: "Services",
                                                           action: .standardServices))
            }
            let menuID = UUID()
            pendingFilterContextMenuID = menuID
            outerframeHost.showContextMenu(
                menuID: menuID,
                items: menuItems,
                at: point,
                attributedText: selectedText.isEmpty ? nil : NSAttributedString(string: selectedText)
            )
            return true
        }

        return true
    }

    private func handleContextMenuSelection(menuID: UUID, itemID: String) {
        if pendingFilterContextMenuID == menuID {
            pendingFilterContextMenuID = nil
            return
        }

        guard pendingCellContextMenuID == menuID else {
            return
        }
        let context = pendingCellFilterContext
        pendingCellContextMenuID = nil
        pendingCellFilterContext = nil

        switch itemID {
        case "include":
            guard let context else { return }
            addFilterClause(FilterClause(column: context.column,
                                         operation: .equals,
                                         value: context.value))
        case "exclude":
            guard let context else { return }
            addFilterClause(FilterClause(column: context.column,
                                         operation: .notEquals,
                                         value: context.value))
        default:
            break
        }
    }

    private func tableCellHit(at point: CGPoint) -> (columnTitle: String, value: String)? {
        let pointInRows = rowsClipLayer.convert(point, from: rootLayer)
        guard rowsClipLayer.bounds.contains(pointInRows) else { return nil }

        let columnFrames = columnFrames(in: rowsClipLayer.bounds.width)
        guard let columnIndex = columnFrames.firstIndex(where: { $0.contains(CGPoint(x: pointInRows.x, y: 0)) }),
              columnIndex >= 0,
              columnIndex < columns.count else {
            return nil
        }

        for (rowIndex, row) in rowLayers.enumerated() {
            guard !row.container.isHidden,
                  row.container.frame.contains(pointInRows),
                  let renderedRow = eventForRenderedRow(at: rowIndex) else {
                continue
            }
            return (columns[columnIndex].title, tableValue(for: renderedRow.event, columnIndex: columnIndex))
        }
        return nil
    }

    private func cellFilterHit(at point: CGPoint) -> (column: FilterColumn, value: String)? {
        let pointInRows = rowsClipLayer.convert(point, from: rootLayer)
        guard rowsClipLayer.bounds.contains(pointInRows) else { return nil }

        let columnFrames = columnFrames(in: rowsClipLayer.bounds.width)
        guard let columnIndex = columnFrames.firstIndex(where: { $0.contains(CGPoint(x: pointInRows.x, y: 0)) }),
              let column = filterColumnForVisibleColumn(at: columnIndex) else {
            return nil
        }

        for (rowIndex, row) in rowLayers.enumerated() {
            guard !row.container.isHidden,
                  row.container.frame.contains(pointInRows),
                  let renderedRow = eventForRenderedRow(at: rowIndex) else {
                continue
            }
            return (column, filterValue(for: renderedRow.event, column: column))
        }
        return nil
    }

    private func tableValue(for event: TraceEvent, columnIndex: Int) -> String {
        switch columnIndex {
        case 0: return event.time
        case 1: return event.type
        case 2: return event.pid > 0 ? String(event.pid) : ""
        case 3: return event.process
        case 4: return event.path
        case 5: return event.detail
        default: return ""
        }
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
        processTimelineScrollOffset = 0
        resetScrollPrediction()
        lastRequestedStart = -1
        lastRequestedCount = -1
        lastRequestedTail = false
        lastRequestedFilterKey = ""
        lastProcessTimelineRequestedFilterKey = ""
        lastProcessTimelineRequestedStart = -1
        lastProcessTimelineRequestedCount = -1
        processTimelineResponse = nil
        processTimelineHasLoaded = false
        processTimelineTotalRows = 0
        processTimelinePageStart = 0
        processTimelineRows = []
        processTimelineDotsByPID = [:]
        hoveredProcessTimelineDot = nil
        processTimelineHoveredDotLayer.path = nil
        updateFilterText()
        updateLayout()
        updateTextInputState()
        fetchVisibleWindow(force: true)
        fetchProcessTimeline(force: true)
    }

    private func applyCaptureStatus(_ status: CaptureStatus) {
        if status.isUnsupported,
           status.unsupportedMessage.isEmpty,
           let existingStatus = captureStorageStatus,
           existingStatus.isUnsupported,
           !existingStatus.unsupportedMessage.isEmpty {
            captureStorageStatus = CaptureStatus(isPaused: status.isPaused,
                                                 pauseReason: status.pauseReason,
                                                 storageStatusValid: status.storageStatusValid,
                                                 storageIsLow: status.storageIsLow,
                                                 isUnsupported: status.isUnsupported,
                                                 unsupportedMessage: existingStatus.unsupportedMessage,
                                                 availableStorageBytes: status.availableStorageBytes,
                                                 storageThresholdBytes: status.storageThresholdBytes,
                                                 totalStorageBytes: status.totalStorageBytes)
            isCapturePaused = status.isPaused
            capturePauseReason = status.pauseReason
            updateStatusText()
            updateCaptureButtonAppearance()
            renderMachineUnsupportedOverlay()
            updateTextInputState()
            return
        }
        isCapturePaused = status.isPaused
        capturePauseReason = status.pauseReason
        captureStorageStatus = status
        updateStatusText()
        updateCaptureButtonAppearance()
        renderMachineUnsupportedOverlay()
        updateTextInputState()
    }

    private func fetchCaptureStatus() {
        guard let captureEndpoint,
              let urlSession else { return }
        urlSession.dataTask(with: captureEndpoint) { [weak self] data, _, _ in
            Task { @MainActor in
                guard let data else { return }
                do {
                    self?.applyCaptureStatus(try decodeCaptureStatusResponse(data))
                } catch {
                    self?.lastErrorText = "Could not decode binary capture response"
                    self?.updateStatusText()
                }
            }
        }.resume()
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

        urlSession.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor in
                if let error {
                    self?.lastErrorText = error.localizedDescription
                    self?.updateStatusText()
                    self?.updateColors()
                } else if let data {
                    do {
                        self?.lastErrorText = nil
                        self?.applyCaptureStatus(try decodeCaptureStatusResponse(data))
                        if paused {
                            self?.fetchVisibleWindow(force: true)
                        } else {
                            self?.lastRequestedStart = -1
                            self?.lastRequestedCount = -1
                            self?.lastRequestedTail = false
                            self?.fetchVisibleWindow(force: true)
                        }
                    } catch {
                        self?.lastErrorText = "Could not decode binary capture response"
                        self?.updateStatusText()
                        self?.fetchVisibleWindow(force: true)
                    }
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

    private func clearLog() {
        guard let clearLogEndpoint,
              let urlSession else { return }

        logGeneration += 1
        inFlight = false
        pendingFetchAfterInFlight = false
        processTimelineInFlight = false
        urlSession.dataTask(with: clearLogEndpoint) { [weak self] data, _, error in
            Task { @MainActor in
                self?.handleClearLogResult(data: data, error: error)
            }
        }.resume()
    }

    private func handleClearLogResult(data: Data?, error: Error?) {
        if let error {
            lastErrorText = error.localizedDescription
            updateStatusText()
            updateColors()
            return
        }
        guard let data else {
            lastErrorText = "No clear response from backend"
            updateStatusText()
            updateColors()
            return
        }

        do {
            guard try decodeClearLogResponse(data) else {
                lastErrorText = "Backend could not clear the log"
                updateStatusText()
                updateColors()
                return
            }
            resetLogStateAfterClear()
            lastErrorText = nil
            updateStatusText()
            updateColors()
            fetchVisibleWindow(force: true)
            fetchProcessTimeline(force: true)
        } catch {
            lastErrorText = "Could not decode clear response"
            updateStatusText()
            updateColors()
        }
    }

    private func resetLogStateAfterClear() {
        totalRows = 0
        unfilteredRows = 0
        currentWindowStart = 0
        currentEvents = []
        scrollOffset = 0
        resetScrollPrediction()
        lastRequestedStart = -1
        lastRequestedCount = -1
        lastRequestedTail = false
        lastRequestedFilterKey = ""
        inFlightFilterKey = ""
        processTimelineResponse = nil
        processTimelineHasLoaded = false
        processTimelineTotalRows = 0
        processTimelinePageStart = 0
        processTimelineRows = []
        processTimelineDotsByPID = [:]
        processTimelineInFlight = false
        pendingProcessTimelineFetchAfterInFlight = false
        lastProcessTimelineRequestedEventCount = 0
        lastProcessTimelineRequestedFilterKey = ""
        lastProcessTimelineRequestedStart = -1
        lastProcessTimelineRequestedCount = -1
        inFlightProcessTimelineFilterKey = ""
        inFlightProcessTimelineStart = 0
        hoveredProcessTimelineDot = nil
        processTimelineHoveredDotLayer.path = nil
        processTimelineScrollOffset = 0
        updateRows()
        updateProcessTimelineRows()
        updateLayout()
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
        if isMachineUnsupported {
            filterCaretLayer.isHidden = true
            filterCaretLayer.removeAnimation(forKey: filterCaretBlinkAnimationKey)
            outerframeHost.setInputMode(.rawKeys)
            outerframeHost.setAcceptedPasteboardPasteTypes([])
            outerframeHost.sendTextInputGeometryUpdate(nil)
            updateEditingCapabilities()
            return
        }
        let inputMode: OuterframeContentInputMode = isFilterPanelExpanded || selectedTableCell != nil ?
            [.textInput, .rawKeys] :
            .rawKeys
        outerframeHost.setInputMode(inputMode)
        updateFilterSelectionLayer()
        guard isFilterPanelExpanded,
              activeFilterIndex >= 0,
              activeFilterIndex < filterValueLayers.count,
              activeFilterIndex < filterClauses.count,
              filterInputController.isFocused,
              !filterInputController.hasSelection else {
            filterCaretLayer.isHidden = true
            filterCaretLayer.removeAnimation(forKey: filterCaretBlinkAnimationKey)
            outerframeHost.sendTextInputGeometryUpdate(nil)
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
        filterCaretLayer.frame = panelCaretRect
        filterCaretLayer.isHidden = false
        filterCaretLayer.opacity = 1
        if filterCaretLayer.animation(forKey: filterCaretBlinkAnimationKey) == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0
            animation.duration = 0.55
            animation.beginTime = CACurrentMediaTime() + 0.55
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            filterCaretLayer.add(animation, forKey: filterCaretBlinkAnimationKey)
        }
        let rootCaretRect = filterPanelLayer.convert(panelCaretRect, to: rootLayer)
        let topLeftY = rootLayer.bounds.height - rootCaretRect.origin.y - rootCaretRect.height
        let geometry = OuterframeContentTextInputGeometry(fieldID: Self.filterFieldID,
                                                          rect: CGRect(x: rootCaretRect.origin.x,
                                                                       y: topLeftY,
                                                                       width: rootCaretRect.width,
                                                                       height: rootCaretRect.height))
        outerframeHost.sendTextInputGeometryUpdate(geometry)
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

    private func offsetForCharacter(line: CTLine,
                                    index: Int,
                                    in text: String,
                                    maxWidth: CGFloat) -> CGFloat {
        let utf16Index = utf16Offset(forCharacterIndex: index, in: text)
        var secondaryOffset: CGFloat = 0
        let primaryOffset = CTLineGetOffsetForStringIndex(line, utf16Index, &secondaryOffset)
        let offset = max(primaryOffset, secondaryOffset)
        return offset.isFinite ? min(max(offset, 0), maxWidth) : 0
    }

    private var isMachineUnsupported: Bool {
        captureStorageStatus?.isUnsupported == true
    }

    private func renderMachineUnsupportedOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        machineUnsupportedOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        machineUnsupportedTextLines.removeAll()
        machineUnsupportedOverlayLayer.frame = rootLayer.bounds
        guard isMachineUnsupported else {
            machineUnsupportedOverlayLayer.isHidden = true
            machineUnsupportedPanelFrame = .zero
            CATransaction.commit()
            return
        }

        let currentAppearance = appearance ?? NSAppearance.currentDrawing()
        currentAppearance.performAsCurrentDrawingAppearance {
            let isDarkMode = currentAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            machineUnsupportedOverlayLayer.isHidden = false
            machineUnsupportedOverlayLayer.backgroundColor = NSColor.black.withAlphaComponent(isDarkMode ? 0.42 : 0.24).cgColor

            let panelWidth = min(max(rootLayer.bounds.width * 0.58, 420), 720)
            let panelHeight: CGFloat = 214
            let panel = CALayer()
            machineUnsupportedPanelFrame = CGRect(x: floor((rootLayer.bounds.width - panelWidth) / 2),
                                                  y: floor((rootLayer.bounds.height - panelHeight) / 2),
                                                  width: panelWidth,
                                                  height: panelHeight)
            panel.frame = machineUnsupportedPanelFrame
            panel.cornerRadius = 12
            panel.borderWidth = 1
            panel.borderColor = NSColor.systemRed.withAlphaComponent(isDarkMode ? 0.55 : 0.42).cgColor
            panel.backgroundColor = NSColor.windowBackgroundColor.cgColor
            panel.shadowColor = NSColor.black.cgColor
            panel.shadowOpacity = isDarkMode ? 0.36 : 0.18
            panel.shadowRadius = 24
            panel.shadowOffset = CGSize(width: 0, height: -8)
            machineUnsupportedOverlayLayer.addSublayer(panel)

            let icon = CALayer()
            icon.contents = makeSystemSymbolImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  pointSize: 28,
                                                  weight: .regular,
                                                  scale: 2,
                                                  tintColor: NSColor.systemRed,
                                                  appearance: currentAppearance)
            icon.contentsGravity = .resizeAspect
            icon.contentsScale = 2
            icon.frame = CGRect(x: 24, y: panelHeight - 62, width: 32, height: 32)
            panel.addSublayer(icon)

            let title = makeTextLayer(size: 18, weight: .semibold)
            title.string = "Firehose cannot be used on this machine"
            title.foregroundColor = NSColor.labelColor.cgColor
            title.frame = CGRect(x: 68, y: panelHeight - 56, width: max(panelWidth - 92, 1), height: 24)
            panel.addSublayer(title)

            let bodyFrame = CGRect(x: 24, y: 28, width: max(panelWidth - 48, 1), height: panelHeight - 104)
            renderMachineUnsupportedSelectableText(machineUnsupportedBodyText(), in: bodyFrame, on: panel)
        }
        CATransaction.commit()
    }

    private func renderMachineUnsupportedSelectableText(_ text: String, in frame: CGRect, on panel: CALayer) {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let lines = wrappedMachineUnsupportedTextLines(text, font: font, frame: frame)
        machineUnsupportedTextLines = lines
        let currentAppearance = appearance ?? NSAppearance.currentDrawing()
        currentAppearance.performAsCurrentDrawingAppearance {
            let isDarkMode = currentAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if let range = machineUnsupportedSelectionRange() {
                for line in lines {
                    guard let intersection = intersectRanges(range, line.range),
                          intersection.lowerBound < intersection.upperBound else { continue }
                    let highlight = CALayer()
                    highlight.actions = noImplicitLayerActions()
                    highlight.frame = selectionRect(for: intersection, in: line)
                    highlight.cornerRadius = 2
                    highlight.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(isDarkMode ? 0.62 : 0.44).cgColor
                    panel.addSublayer(highlight)
                }
            }
            for line in lines {
                let layer = makeTextLayer(size: 13, weight: .regular)
                layer.string = line.text
                layer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                layer.frame = line.frame
                panel.addSublayer(layer)
            }
        }
    }

    private func wrappedMachineUnsupportedTextLines(_ text: String,
                                                    font: NSFont,
                                                    frame: CGRect) -> [MachineUnsupportedTextLine] {
        guard !text.isEmpty else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let nsText = text as NSString
        let lineHeight: CGFloat = 17
        let maxLines = max(Int(floor(frame.height / lineHeight)), 1)
        var utf16Start = 0
        var result: [MachineUnsupportedTextLine] = []
        while utf16Start < nsText.length, result.count < maxLines {
            var length = CTTypesetterSuggestLineBreak(typesetter, utf16Start, Double(frame.width))
            if length <= 0 { length = 1 }
            let nsRange = NSRange(location: utf16Start, length: min(length, nsText.length - utf16Start))
            var lineText = nsText.substring(with: nsRange)
            while lineText.hasSuffix("\n") || lineText.hasSuffix("\r") {
                lineText.removeLast()
            }
            let charStart = characterIndex(forUTF16: nsRange.location, in: text)
            let charEnd = characterIndex(forUTF16: nsRange.location + nsRange.length, in: text)
            let y = frame.maxY - CGFloat(result.count + 1) * lineHeight
            result.append(MachineUnsupportedTextLine(text: lineText,
                                                     range: charStart..<charEnd,
                                                     frame: CGRect(x: frame.minX,
                                                                   y: y,
                                                                   width: frame.width,
                                                                   height: lineHeight),
                                                     font: font))
            utf16Start += nsRange.length
        }
        return result
    }

    private func machineUnsupportedSelectionRange() -> Range<Int>? {
        guard let anchor = machineUnsupportedSelectionAnchor,
              let focus = machineUnsupportedSelectionFocus,
              anchor != focus else { return nil }
        return min(anchor, focus)..<max(anchor, focus)
    }

    private func intersectRanges(_ first: Range<Int>, _ second: Range<Int>) -> Range<Int>? {
        let lower = max(first.lowerBound, second.lowerBound)
        let upper = min(first.upperBound, second.upperBound)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private func selectionRect(for range: Range<Int>, in line: MachineUnsupportedTextLine) -> CGRect {
        let lineObject = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: line.font]))
        let lowerIndex = min(max(range.lowerBound - line.range.lowerBound, 0), line.text.count)
        let upperIndex = min(max(range.upperBound - line.range.lowerBound, 0), line.text.count)
        let lower = offsetForCharacter(line: lineObject,
                                       index: lowerIndex,
                                       in: line.text,
                                       maxWidth: line.frame.width)
        let upper = offsetForCharacter(line: lineObject,
                                       index: upperIndex,
                                       in: line.text,
                                       maxWidth: line.frame.width)
        return CGRect(x: line.frame.minX + min(lower, upper),
                      y: line.frame.minY + 1,
                      width: max(abs(upper - lower), 1),
                      height: line.frame.height - 2)
    }

    private func machineUnsupportedBodyText() -> String {
        let message = captureStorageStatus?.unsupportedMessage.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let intro = "Firehose cannot capture events on this machine because the Linux kernel does not support the required event tracing features."
        if message.isEmpty {
            return "\(intro)\n\nRequired feature: Linux eBPF event capture"
        }

        var details: [String] = []
        if message.contains("BPF_MAP_CREATE") {
            details.append("Required feature: eBPF maps / BPF_MAP_CREATE")
        }
        if message.contains("Function not implemented") {
            details.append("Kernel response: Function not implemented")
        }
        let detailText = details.isEmpty ? message : details.joined(separator: "\n")
        return "\(intro)\n\nTechnical details:\n\(detailText)"
    }

    private func machineUnsupportedCharacterIndex(at point: CGPoint) -> Int? {
        guard isMachineUnsupported,
              !machineUnsupportedPanelFrame.isEmpty,
              machineUnsupportedPanelFrame.contains(point) else { return nil }
        let localPoint = CGPoint(x: point.x - machineUnsupportedPanelFrame.minX,
                                 y: point.y - machineUnsupportedPanelFrame.minY)
        guard !machineUnsupportedTextLines.isEmpty else { return nil }

        if localPoint.y >= machineUnsupportedTextLines[0].frame.maxY {
            return machineUnsupportedTextLines[0].range.lowerBound
        }
        if localPoint.y <= machineUnsupportedTextLines[machineUnsupportedTextLines.count - 1].frame.minY {
            return machineUnsupportedTextLines[machineUnsupportedTextLines.count - 1].range.upperBound
        }

        let line = machineUnsupportedTextLines.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(localPoint) })
        guard let line else { return nil }
        let clampedX = min(max(localPoint.x - line.frame.minX, 0), line.frame.width)
        guard !line.text.isEmpty else { return line.range.lowerBound }
        let lineObject = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: line.font]))
        let utf16Index = CTLineGetStringIndexForPosition(lineObject, CGPoint(x: clampedX, y: 0))
        if utf16Index == kCFNotFound {
            return clampedX > line.frame.width * 0.5 ? line.range.upperBound : line.range.lowerBound
        }
        return min(line.range.upperBound,
                   line.range.lowerBound + characterIndex(forUTF16: utf16Index, in: line.text))
    }

    private func handleMachineUnsupportedMouseDown(at point: CGPoint, clickCount: Int) {
        guard let index = machineUnsupportedCharacterIndex(at: point) else {
            clearMachineUnsupportedSelection()
            return
        }
        if clickCount >= 3 {
            let range = machineUnsupportedParagraphRange(containing: index)
            machineUnsupportedSelectionAnchor = range.lowerBound
            machineUnsupportedSelectionFocus = range.upperBound
            isSelectingMachineUnsupportedText = false
        } else if clickCount == 2 {
            let range = machineUnsupportedWordRange(containing: index)
            machineUnsupportedSelectionAnchor = range.lowerBound
            machineUnsupportedSelectionFocus = range.upperBound
            isSelectingMachineUnsupportedText = false
        } else {
            machineUnsupportedSelectionAnchor = index
            machineUnsupportedSelectionFocus = index
            isSelectingMachineUnsupportedText = true
        }
        renderMachineUnsupportedOverlay()
    }

    private func machineUnsupportedWordRange(containing index: Int) -> Range<Int> {
        let text = machineUnsupportedBodyText()
        guard !text.isEmpty else { return 0..<0 }
        let characters = Array(text)
        var location = min(max(index, 0), characters.count - 1)
        if location > 0, !isMachineUnsupportedWordCharacter(characters[location]) {
            location -= 1
        }
        guard isMachineUnsupportedWordCharacter(characters[location]) else {
            let clamped = min(max(index, 0), characters.count)
            return clamped..<clamped
        }

        var start = location
        while start > 0, isMachineUnsupportedWordCharacter(characters[start - 1]) {
            start -= 1
        }
        var end = location + 1
        while end < characters.count, isMachineUnsupportedWordCharacter(characters[end]) {
            end += 1
        }
        return start..<end
    }

    private func machineUnsupportedParagraphRange(containing index: Int) -> Range<Int> {
        let text = machineUnsupportedBodyText()
        guard !text.isEmpty else { return 0..<0 }
        let characters = Array(text)
        var location = min(max(index, 0), characters.count - 1)
        if location > 0, characters[location] == "\n" {
            location -= 1
        }

        var start = location
        while start > 0, characters[start - 1] != "\n" {
            start -= 1
        }
        var end = location
        while end < characters.count, characters[end] != "\n" {
            end += 1
        }
        return start..<end
    }

    private func isMachineUnsupportedWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "_-./~:".unicodeScalars.contains(scalar)
    }

    private func handleMachineUnsupportedMouseDragged(at point: CGPoint) {
        guard isSelectingMachineUnsupportedText else { return }
        machineUnsupportedSelectionFocus = machineUnsupportedCharacterIndex(at: point)
            ?? (point.y < machineUnsupportedPanelFrame.midY ? machineUnsupportedBodyText().count : 0)
        renderMachineUnsupportedOverlay()
    }

    private func handleMachineUnsupportedMouseUp(at point: CGPoint) {
        guard isSelectingMachineUnsupportedText else { return }
        isSelectingMachineUnsupportedText = false
        if let index = machineUnsupportedCharacterIndex(at: point) {
            machineUnsupportedSelectionFocus = index
        }
        renderMachineUnsupportedOverlay()
    }

    private func clearMachineUnsupportedSelection() {
        machineUnsupportedSelectionAnchor = nil
        machineUnsupportedSelectionFocus = nil
        isSelectingMachineUnsupportedText = false
        renderMachineUnsupportedOverlay()
    }

    private func machineUnsupportedSelectedText() -> String? {
        guard let range = machineUnsupportedSelectionRange() else { return nil }
        let text = machineUnsupportedBodyText()
        let lower = min(max(range.lowerBound, 0), text.count)
        let upper = min(max(range.upperBound, lower), text.count)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        let selected = String(text[start..<end])
        return selected.isEmpty ? nil : selected
    }

    private func machineUnsupportedPasteboardItems() -> [OuterframeContentPasteboardItem] {
        guard let selectedText = machineUnsupportedSelectedText() else { return [] }
        return stringPasteboardItems(for: selectedText)
    }

    private func writeMachineUnsupportedSelectionToPasteboard() {
        let items = machineUnsupportedPasteboardItems()
        guard !items.isEmpty else { return }
        outerframeHost.requestPasteboardWrite(items: items) { _ in }
    }

    private func handleMachineUnsupportedKeyDown(charactersIgnoringModifiers: String,
                                                 modifierFlags: NSEvent.ModifierFlags) {
        guard modifierFlags.contains(.command) else { return }
        switch charactersIgnoringModifiers.lowercased() {
        case "c":
            writeMachineUnsupportedSelectionToPasteboard()
        case "a":
            machineUnsupportedSelectionAnchor = 0
            machineUnsupportedSelectionFocus = machineUnsupportedBodyText().count
            renderMachineUnsupportedOverlay()
        default:
            break
        }
    }

    private func showMachineUnsupportedContextMenu(at point: CGPoint) {
        if machineUnsupportedCharacterIndex(at: point) == nil, machineUnsupportedSelectedText() == nil {
            return
        }
        let menuID = UUID()
        machineUnsupportedContextMenuIDs.insert(menuID)
        let items = [
            OuterframeContextMenuItem(id: "copy",
                                      title: "Copy",
                                      action: .standardCopy,
                                      isEnabled: machineUnsupportedSelectedText() != nil)
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func handleMachineUnsupportedContextMenuSelection(menuID: UUID, itemID: String) {
        guard machineUnsupportedContextMenuIDs.remove(menuID) != nil else { return }
        if itemID == "copy" {
            writeMachineUnsupportedSelectionToPasteboard()
        }
    }

    private func updateEditingCapabilities() {
        if isMachineUnsupported {
            outerframeHost.setAcceptedPasteboardPasteTypes([])
            return
        }
        if filterInputController.isFocused {
            let acceptedTypes = filterInputController.currentAcceptedPasteboardTypeIdentifiers()
            outerframeHost.setAcceptedPasteboardPasteTypes(acceptedTypes)
            return
        }

        outerframeHost.setAcceptedPasteboardPasteTypes([])
    }

    private func enabledEditCommands(in requestedCommands: OuterframeEditCommandSet) -> OuterframeEditCommandSet {
        if isMachineUnsupported {
            var enabledCommands: OuterframeEditCommandSet = []
            if machineUnsupportedSelectedText() != nil, requestedCommands.contains(.copy) {
                enabledCommands.insert(.copy)
            }
            if requestedCommands.contains(.selectAll), !machineUnsupportedBodyText().isEmpty {
                enabledCommands.insert(.selectAll)
            }
            return enabledCommands
        }
        if filterInputController.isFocused {
            return filterInputController.enabledEditCommands(in: requestedCommands)
        }

        var enabledCommands: OuterframeEditCommandSet = []
        if requestedCommands.contains(.copy), selectedTableCell?.value.isEmpty == false {
            enabledCommands.insert(.copy)
        }
        return enabledCommands
    }

    private func pasteboardItemsForCopy() -> [OuterframeContentPasteboardItem] {
        if isMachineUnsupported {
            return machineUnsupportedPasteboardItems()
        }
        if filterInputController.isFocused,
           let selectedText = filterInputController.selectedTextContent(),
           !selectedText.isEmpty {
            return stringPasteboardItems(for: selectedText)
        }

        if let selectedTableCell,
           !selectedTableCell.value.isEmpty {
            return stringPasteboardItems(for: selectedTableCell.value)
        }

        return []
    }

    private func handlePasteboardItemsForPaste(_ items: [OuterframeContentPasteboardItem]) {
        guard filterInputController.isFocused else { return }

        for item in items {
            for representation in item.representations {
                if representation.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue,
                   let stringValue = String(data: representation.data, encoding: .utf8) {
                    filterInputController.insertText(stringValue)
                    return
                }

                if representation.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue,
                   let attributed = try? NSAttributedString(data: representation.data,
                                                            options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                            documentAttributes: nil) {
                    filterInputController.insertText(attributed.string)
                    return
                }
            }
        }
    }

    private func stringPasteboardItems(for value: String) -> [OuterframeContentPasteboardItem] {
        [OuterframeContentPasteboardItem(representations: [
            OuterframeContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                      data: Data(value.utf8))
        ])]
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
        let range = renderedRowRange()
        let needed = max(range.end - range.start, 1)
        while rowLayers.count < needed {
            rowLayers.append(makeRowLayers())
        }
        for (index, row) in rowLayers.enumerated() {
            row.container.isHidden = index >= needed || eventForRenderedRow(at: index) == nil
        }
    }

    private func updateTimelineRowLayerCount() {
        let visibleRows = max(Int(ceil(processTimelineRowsClipLayer.bounds.height / processTimelineRowHeight)), 1)
        let needed = min(max(visibleRows + 1, 1), max(processTimelineTotalRows, 1))
        while timelineRowLayers.count < needed {
            timelineRowLayers.append(makeTimelineRowLayers())
        }
        for (index, row) in timelineRowLayers.enumerated() {
            row.container.isHidden = index >= needed || processTimelineTotalRows == 0
        }
    }

    private func processTimelineVisibleStartIndex() -> Int {
        min(max(Int(floor(processTimelineScrollOffset / processTimelineRowHeight)), 0),
            max(processTimelineTotalRows - 1, 0))
    }

    private func processTimelinePageIndex(forGlobalIndex index: Int) -> Int? {
        let pageIndex = index - processTimelinePageStart
        guard pageIndex >= 0,
              pageIndex < processTimelineRows.count else {
            return nil
        }
        return pageIndex
    }

    private func processTimelineRow(forGlobalIndex index: Int) -> TimelineProcessRow? {
        guard let pageIndex = processTimelinePageIndex(forGlobalIndex: index) else {
            return nil
        }
        return processTimelineRows[pageIndex]
    }

    private func visibleProcessTimelineRowRange() -> (start: Int, end: Int) {
        let viewportHeight = max(processTimelineRowsClipLayer.bounds.height, processTimelineRowHeight)
        let start = processTimelineVisibleStartIndex()
        let end = max(Int(ceil((processTimelineScrollOffset + viewportHeight) / processTimelineRowHeight)), start + 1)
        let boundedTotal = max(processTimelineTotalRows, end)
        return (start, min(end, boundedTotal))
    }

    private func desiredProcessTimelineWindow() -> (start: Int, count: Int) {
        let visible = visibleProcessTimelineRowRange()
        let visibleCount = max(visible.end - visible.start, 1)
        let overscan = max(processTimelineRenderedRowOverscan, visibleCount)
        let boundedTotal = processTimelineTotalRows > 0 ?
            max(processTimelineTotalRows, visible.end) :
            max(processTimelineMinPrefetchRows, visible.end)
        var start = max(visible.start - overscan, 0)
        var end = min(max(visible.end + overscan, start + processTimelineMinPrefetchRows), boundedTotal)
        if end - start < processTimelineMinPrefetchRows {
            start = max(0, min(start, end - processTimelineMinPrefetchRows))
            end = min(boundedTotal, max(end, start + processTimelineMinPrefetchRows))
        }
        if end - start > processTimelineMaxPrefetchRows {
            let center = (visible.start + visible.end) / 2
            start = max(0, center - processTimelineMaxPrefetchRows / 2)
            end = min(boundedTotal, start + processTimelineMaxPrefetchRows)
            start = max(0, end - processTimelineMaxPrefetchRows)
        }
        return (start, max(end - start, 1))
    }

    private func processTimelineResponseCoversDesiredWindow() -> Bool {
        let desired = desiredProcessTimelineWindow()
        let desiredEnd = min(desired.start + desired.count, max(processTimelineTotalRows, desired.start + desired.count))
        let responseEnd = processTimelinePageStart + processTimelineRows.count
        if processTimelineTotalRows == 0 {
            return processTimelineHasLoaded
        }
        return desired.start >= processTimelinePageStart && desiredEnd <= responseEnd
    }

    private func visibleRowRange(for offset: CGFloat) -> (start: Int, end: Int) {
        let viewportHeight = max(rowsClipLayer.bounds.height, rowHeight)
        let start = max(Int(floor(offset / rowHeight)), 0)
        let end = max(Int(ceil((offset + viewportHeight) / rowHeight)), start + 1)
        return (start, end)
    }

    private func renderedRowRange() -> (start: Int, end: Int) {
        let visible = visibleRowRange(for: scrollOffset)
        let visibleCount = max(visible.end - visible.start, 1)
        let overscan = max(renderedRowOverscan, visibleCount / 2)
        let boundedTotal = max(totalRows, visible.end)
        let start = max(visible.start - overscan, 0)
        let end = min(max(visible.end + overscan, start + visibleCount), boundedTotal)
        return (start, max(end, start + 1))
    }

    private func eventForRenderedRow(at index: Int) -> (globalIndex: Int, event: TraceEvent)? {
        let renderedStart = renderedRowRange().start
        let globalIndex = renderedStart + index
        let eventIndex = globalIndex - currentWindowStart
        guard eventIndex >= 0,
              eventIndex < currentEvents.count else {
            return nil
        }
        return (globalIndex, currentEvents[eventIndex])
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

    private func activeFilterQueryItems() -> [URLQueryItem] {
        let clauses = activeFilterClauses()
        var queryItems = [URLQueryItem(name: "filterCount", value: String(clauses.count))]
        for (index, clause) in clauses.enumerated() {
            queryItems.append(URLQueryItem(name: "f\(index)column", value: clause.column.rawValue))
            queryItems.append(URLQueryItem(name: "f\(index)op", value: clause.operation.rawValue))
            queryItems.append(URLQueryItem(name: "f\(index)value", value: clause.value))
        }
        return queryItems
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
        queryItems.append(contentsOf: activeFilterQueryItems())
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
        let requestGeneration = logGeneration
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            let errorText = error?.localizedDescription
            Task { @MainActor in
                self?.handleFetchResult(data: data,
                                        errorText: errorText,
                                        generation: requestGeneration)
            }
        }.resume()
    }

    private func handleFetchResult(data: Data?, errorText: String?, generation: Int) {
        guard generation == logGeneration else { return }
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
            applyCaptureStatus(response.captureStatus)
            if wasPinnedToBottom {
                scrollOffset = maxScrollOffset()
            }
            currentWindowStart = response.start
            currentEvents = response.events
            lastErrorText = nil
            clampScrollOffset()
            updateRows()
            updateLayout()
            requestProcessTimelineRefreshIfNeeded(eventCount: UInt64(response.unfilteredTotal))
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

    private func fetchProcessTimeline(force: Bool) {
        guard let processTimelineEndpoint,
              let urlSession else { return }
        if processTimelineInFlight {
            pendingProcessTimelineFetchAfterInFlight = true
            return
        }

        let window = desiredProcessTimelineWindow()
        let start = window.start
        let count = window.count
        let filterKey = currentFilterKey()
        if !force &&
            filterKey == lastProcessTimelineRequestedFilterKey &&
            start == lastProcessTimelineRequestedStart &&
            count == lastProcessTimelineRequestedCount &&
            processTimelineResponseCoversDesiredWindow() {
            return
        }

        var components = URLComponents(url: processTimelineEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: String(count))
        ]
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: activeFilterQueryItems())
        components?.queryItems = queryItems
        guard let url = components?.url else { return }
        pendingProcessTimelineFetchAfterInFlight = false
        processTimelineInFlight = true
        lastProcessTimelineRequestedStart = start
        lastProcessTimelineRequestedCount = count
        lastProcessTimelineRequestedFilterKey = filterKey
        inFlightProcessTimelineFilterKey = filterKey
        inFlightProcessTimelineStart = start
        let requestGeneration = logGeneration
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            let errorText = error?.localizedDescription
            Task { @MainActor in
                self?.handleProcessTimelineFetchResult(data: data,
                                                       errorText: errorText,
                                                       generation: requestGeneration)
            }
        }.resume()
    }

    private func requestProcessTimelineRefreshIfNeeded(eventCount: UInt64) {
        let filterKey = currentFilterKey()
        guard eventCount != lastProcessTimelineRequestedEventCount ||
              filterKey != lastProcessTimelineRequestedFilterKey else { return }
        lastProcessTimelineRequestedEventCount = eventCount
        lastProcessTimelineRequestedStart = -1
        lastProcessTimelineRequestedCount = -1
        fetchProcessTimeline(force: false)
    }

    private func handleProcessTimelineFetchResult(data: Data?, errorText: String?, generation: Int) {
        guard generation == logGeneration else { return }
        processTimelineInFlight = false
        let responseFilterKey = inFlightProcessTimelineFilterKey
        let responseStart = inFlightProcessTimelineStart
        inFlightProcessTimelineFilterKey = ""
        inFlightProcessTimelineStart = 0
        let hadPendingFetch = pendingProcessTimelineFetchAfterInFlight
        pendingProcessTimelineFetchAfterInFlight = false
        if responseFilterKey != currentFilterKey() {
            fetchProcessTimeline(force: true)
            return
        }
        if let errorText {
            lastErrorText = errorText
            updateStatusText()
            if hadPendingFetch {
                fetchProcessTimeline(force: false)
            }
            return
        }
        guard let data else {
            lastErrorText = "No process timeline response from backend"
            updateStatusText()
            if hadPendingFetch {
                fetchProcessTimeline(force: false)
            }
            return
        }

        do {
            let response = try decodeProcessTimelineResponse(data)
            processTimelineResponse = response
            processTimelineHasLoaded = true
            processTimelineTotalRows = response.processCount
            processTimelinePageStart = responseStart
            processTimelineRows = response.processes.map { TimelineProcessRow(process: $0, level: $0.level) }
            processTimelineDotsByPID = Dictionary(grouping: response.eventDots, by: \.pid)
            clampProcessTimelineScrollOffset()
            updateProcessTimelineRows()
            updateLayout()
            let shouldRefetch = !processTimelineResponseCoversDesiredWindow()
            if shouldRefetch || hadPendingFetch {
                fetchProcessTimeline(force: true)
            }
        } catch {
            lastErrorText = "Could not decode process timeline response"
            updateStatusText()
        }
        if hadPendingFetch && !processTimelineInFlight {
            fetchProcessTimeline(force: false)
        }
    }

    private func updateProcessTimelineRows() {
        withoutImplicitAnimations {
            updateTimelineRowLayerCount()
            layoutTimelineRows()
        }
        notifyAccessibilityLayoutChanged()
    }

    private func jumpToEvent(for pid: Int,
                             nearTimestamp timestamp: Double? = nil,
                             bucketIndex: Int? = nil) {
        guard pid > 0,
              let eventPositionEndpoint,
              let urlSession else { return }

        var components = URLComponents(url: eventPositionEndpoint, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "pid", value: String(pid))]
        if let timestamp {
            queryItems.append(URLQueryItem(name: "time", value: String(timestamp)))
        }
        if let bucketIndex,
           let response = processTimelineResponse,
           bucketIndex >= 0,
           bucketIndex < response.eventDotBucketCount {
            queryItems.append(URLQueryItem(name: "bucket", value: String(bucketIndex)))
            queryItems.append(URLQueryItem(name: "bucketCount", value: String(response.eventDotBucketCount)))
            queryItems.append(URLQueryItem(name: "rangeStart", value: String(response.captureStart)))
            queryItems.append(URLQueryItem(name: "rangeEnd", value: String(response.captureEnd)))
        }
        queryItems.append(contentsOf: activeFilterQueryItems())
        components?.queryItems = queryItems
        guard let url = components?.url else { return }

        urlSession.dataTask(with: url) { [weak self] data, _, error in
            let errorText = error?.localizedDescription
            Task { @MainActor in
                self?.handleEventPositionResult(data: data, errorText: errorText)
            }
        }.resume()
    }

    private func handleEventPositionResult(data: Data?, errorText: String?) {
        if let errorText {
            lastErrorText = errorText
            updateStatusText()
            return
        }
        guard let data else {
            lastErrorText = "No event position response from backend"
            updateStatusText()
            return
        }

        do {
            let response = try decodeEventPositionResponse(data)
            guard response.found else { return }
            scrollToFilteredEventIndex(response.index)
        } catch {
            lastErrorText = "Could not decode binary event position response"
            updateStatusText()
        }
    }

    private func scrollToFilteredEventIndex(_ index: Int) {
        guard index >= 0 else { return }
        scrollOffset = CGFloat(index) * rowHeight
        resetScrollPrediction()
        clampScrollOffset()
        lastRequestedStart = -1
        lastRequestedCount = -1
        lastRequestedTail = false
        updateLayout()
        fetchVisibleWindow(force: true)
    }

    private func updateRows() {
        withoutImplicitAnimations {
            updateRowLayerCount()
            for (index, row) in rowLayers.enumerated() {
                guard let renderedRow = eventForRenderedRow(at: index) else {
                    row.container.isHidden = true
                    continue
                }
                let event = renderedRow.event
                row.container.isHidden = false
                row.time.string = event.time
                row.type.string = event.type
                row.pid.string = event.pid > 0 ? String(event.pid) : ""
                row.process.string = event.process
                row.path.string = event.path
                row.detail.string = event.detail
                row.background.opacity = (renderedRow.globalIndex % 2 == 0) ? 0.38 : 0
            }
        }
        notifyAccessibilityLayoutChanged()
    }

    private func updateStatusText() {
        withoutImplicitAnimations {
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                if let lastErrorText {
                    statusLayer.string = "Backend unavailable: \(lastErrorText)"
                    statusLayer.foregroundColor = NSColor.systemRed.cgColor
                    return
                }
                let shownRows = totalRows
                let denominator = max(unfilteredRows, totalRows)
                let percentage = denominator > 0 ? Int((Double(shownRows) / Double(denominator) * 100).rounded()) : 0
                let processText: String
                if processTimelineHasLoaded {
                    processText = " - \(formatCount(processTimelineTotalRows)) processes"
                } else {
                    processText = ""
                }
                let baseText = "Showing \(formatCount(shownRows)) of \(formatCount(denominator)) events (\(percentage)%)\(processText)"
                if let captureStorageStatus,
                   captureStorageStatus.isUnsupported {
                    let message = captureStorageStatus.unsupportedMessage.isEmpty
                        ? "Firehose cannot capture events on this machine"
                        : captureStorageStatus.unsupportedMessage
                    statusLayer.string = message
                    statusLayer.foregroundColor = NSColor.systemRed.cgColor
                } else if let captureStorageStatus,
                   captureStorageStatus.storageStatusValid,
                   capturePauseReason == .lowStorage {
                    statusLayer.string = "\(baseText) - Tracing paused: low storage (\(formatByteCount(captureStorageStatus.availableStorageBytes)) available)"
                    statusLayer.foregroundColor = NSColor.systemOrange.cgColor
                } else if isCapturePaused {
                    statusLayer.string = "\(baseText) - Tracing paused"
                    statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                } else {
                    statusLayer.string = baseText
                    statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                }
            }
        }
        notifyAccessibilityLayoutChanged()
    }

    private func clampScrollOffset() {
        scrollOffset = min(max(scrollOffset, 0), maxScrollOffset())
    }

    private func clampProcessTimelineScrollOffset() {
        processTimelineScrollOffset = min(max(processTimelineScrollOffset, 0), maxProcessTimelineScrollOffset())
    }

    private func maxScrollOffset() -> CGFloat {
        let contentHeight = CGFloat(totalRows) * rowHeight
        return max(contentHeight - rowsClipLayer.bounds.height, 0)
    }

    private func maxProcessTimelineScrollOffset() -> CGFloat {
        let contentHeight = CGFloat(processTimelineTotalRows) * processTimelineRowHeight
        return max(contentHeight - processTimelineRowsClipLayer.bounds.height, 0)
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
                processTimelineLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
                toolbarLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
                headerLayer.backgroundColor = NSColor.controlBackgroundColor.cgColor
                let controlBrightness = NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 1
                let isLightTheme = controlBrightness > 0.6
                let dividerColor = NSColor.separatorColor.withAlphaComponent(isLightTheme ? 0.35 : 0.6).cgColor
                headerBorderLayer.backgroundColor = dividerColor
                rowsClipLayer.backgroundColor = NSColor.textBackgroundColor.cgColor
                scrollbarTrackLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
                scrollbarThumbLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.36).cgColor
                processTimelineRowsClipLayer.backgroundColor = NSColor.textBackgroundColor.cgColor
                processTimelineDividerLayer.backgroundColor = dividerColor
                processTimelineEmptyLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
                let eventDotAlphas: [CGFloat] = [0.44, 0.58, 0.72, 0.86]
                for (index, dotLayer) in processTimelineEventDotLayers.enumerated() {
                    dotLayer.fillColor = NSColor.secondaryLabelColor
                        .withAlphaComponent(eventDotAlphas[min(index, eventDotAlphas.count - 1)])
                        .cgColor
                }
                processTimelineHoveredDotLayer.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.92).cgColor
                processTimelineHoveredDotLayer.strokeColor = nil
                processTimelineHoveredDotLayer.lineWidth = 0
                processTimelineScrollbarTrackLayer.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
                processTimelineScrollbarThumbLayer.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.36).cgColor
                pauseButtonLayer.backgroundColor = NSColor.clear.cgColor
                clearLogButtonLayer.backgroundColor = NSColor.clear.cgColor
                filterPillLayer.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
                filterPillLayer.borderColor = NSColor.separatorColor.cgColor
                filterPillTextLayer.foregroundColor = NSColor.labelColor.cgColor
                filterPanelLayer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
                filterPanelLayer.borderColor = NSColor.separatorColor.cgColor
                filterCaretLayer.backgroundColor = NSColor.textColor.cgColor
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
                updateStatusText()
                updateCaptureButtonAppearance()
                updateClearLogButtonAppearance()
                for row in rowLayers {
                    applyColors(to: row)
                }
                for row in timelineRowLayers {
                    applyColors(to: row)
                }
                renderMachineUnsupportedOverlay()
            }
        }
    }

    private func applyColors(to row: RowLayers) {
        appearance?.performAsCurrentDrawingAppearance {
            row.background.backgroundColor = NSColor.controlBackgroundColor.cgColor
            row.time.foregroundColor = NSColor.secondaryLabelColor.cgColor
            row.type.foregroundColor = NSColor.labelColor.cgColor
            row.pid.foregroundColor = NSColor.secondaryLabelColor.cgColor
            row.process.foregroundColor = NSColor.labelColor.cgColor
            row.path.foregroundColor = NSColor.labelColor.cgColor
            row.detail.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func applyColors(to row: TimelineRowLayers) {
        appearance?.performAsCurrentDrawingAppearance {
            row.background.backgroundColor = NSColor.controlBackgroundColor.cgColor
            row.name.foregroundColor = NSColor.labelColor.cgColor
            row.pid.foregroundColor = NSColor.secondaryLabelColor.cgColor
            row.events.foregroundColor = NSColor.secondaryLabelColor.cgColor
            row.barTrack.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.30).cgColor
            row.bar.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
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
            let tint: NSColor
            if capturePauseReason == .lowStorage {
                tint = NSColor.systemOrange
            } else {
                tint = isCapturePaused ? NSColor.labelColor : NSColor.controlAccentColor
            }
            pauseButtonIconLayer.contents = makeSystemSymbolImage(systemSymbolName: symbolName,
                                                                  pointSize: toolbarButtonSymbolPointSize,
                                                                  weight: .regular,
                                                                  scale: max(pauseButtonIconLayer.contentsScale, 2),
                                                                  tintColor: tint,
                                                                  appearance: appearance ?? NSAppearance.currentDrawing())
        }
    }

    private func updateClearLogButtonAppearance() {
        appearance?.performAsCurrentDrawingAppearance {
            clearLogButtonIconLayer.contents = makeSystemSymbolImage(systemSymbolName: "xmark.circle",
                                                                     pointSize: toolbarButtonSymbolPointSize,
                                                                     weight: .regular,
                                                                     scale: max(clearLogButtonIconLayer.contentsScale, 2),
                                                                     tintColor: NSColor.secondaryLabelColor,
                                                                     appearance: appearance ?? NSAppearance.currentDrawing())
        }
    }

    private func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formatCompactCount(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return "\(value / 1_000_000)m"
        }
        if value >= 1_000 {
            return "\(value / 1_000)k"
        }
        return String(value)
    }

    private func formatByteCount(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))))
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        if seconds < 60 {
            return String(format: "%.1f s", seconds)
        }
        let minutes = Int(seconds / 60)
        let remainder = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(remainder)s"
    }

    private func withoutImplicitAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func noImplicitLayerActions() -> [String: CAAction] {
        [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "opacity": NSNull(),
            "backgroundColor": NSNull(),
            "contents": NSNull()
        ]
    }

    private func accessibilitySnapshot() -> OuterframeAccessibilitySnapshot? {
        var nextIdentifier: UInt32 = 1
        var children: [OuterframeAccessibilityNode] = []

        children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                          role: .staticText,
                                          frame: toolbarLayer.convert(statusLayer.frame, to: rootLayer),
                                          label: statusLayer.string as? String ?? ""))
        children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                          role: .button,
                                          frame: toolbarLayer.convert(pauseButtonLayer.frame, to: rootLayer),
                                          label: isCapturePaused ? "Resume tracing" : "Pause tracing",
                                          hint: capturePauseReason == .lowStorage ? "Tracing paused because storage is low" : nil,
                                          isEnabled: capturePauseReason != .lowStorage))
        children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                          role: .button,
                                          frame: toolbarLayer.convert(clearLogButtonLayer.frame, to: rootLayer),
                                          label: "Clear log"))
        children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                          role: .button,
                                          frame: toolbarLayer.convert(filterPillLayer.frame, to: rootLayer),
                                          label: "Filters",
                                          value: currentFilterSummary(),
                                          hint: isFilterPanelExpanded ? "Filter editor expanded" : "Open filter editor"))
        if isFilterPanelExpanded {
            children.append(buildFilterAccessibilityNode(nextIdentifier: &nextIdentifier))
        }
        children.append(buildEventTableAccessibilityNode(nextIdentifier: &nextIdentifier))
        children.append(buildProcessTimelineAccessibilityNode(nextIdentifier: &nextIdentifier))

        let rootNode = OuterframeAccessibilityNode(identifier: 0,
                                                   role: .container,
                                                   frame: rootLayer.bounds,
                                                   label: "Firehose event monitor",
                                                   children: children)
        return OuterframeAccessibilitySnapshot(rootNodes: [rootNode])
    }

    private func buildFilterAccessibilityNode(nextIdentifier: inout UInt32) -> OuterframeAccessibilityNode {
        var children: [OuterframeAccessibilityNode] = []
        for (index, clause) in filterClauses.enumerated() where index < filterRowLayers.count {
            let label = "\(clause.column.title) \(clause.operation.title) \(clause.value.isEmpty ? "empty value" : clause.value)"
            children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                             role: .row,
                                             frame: filterPanelLayer.convert(filterRowLayers[index].frame, to: rootLayer),
                                             label: label,
                                             hint: index == activeFilterIndex ? "Active filter row" : nil))
        }
        children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                         role: .textField,
                                         frame: filterPanelLayer.convert(filterValueLayers.indices.contains(activeFilterIndex) ? filterValueLayers[activeFilterIndex].frame : filterAddLayer.frame, to: rootLayer),
                                         label: "Filter value",
                                         value: activeFilterValue()))
        children.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                         role: .button,
                                         frame: filterPanelLayer.convert(filterAddLayer.frame, to: rootLayer),
                                         label: "Add filter"))
        return accessibilityNode(nextIdentifier: &nextIdentifier,
                                 role: .container,
                                 frame: filterPanelLayer.frame,
                                 label: "Filter editor",
                                 children: children)
    }

    private func buildEventTableAccessibilityNode(nextIdentifier: inout UInt32) -> OuterframeAccessibilityNode {
        var rows: [OuterframeAccessibilityNode] = []
        for (index, row) in rowLayers.enumerated() where !row.container.isHidden {
            guard let renderedRow = eventForRenderedRow(at: index) else { continue }
            let event = renderedRow.event
            let cells = [
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.time.frame, to: rootLayer),
                                  label: "Time",
                                  value: event.time),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.type.frame, to: rootLayer),
                                  label: "Event",
                                  value: event.type),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.pid.frame, to: rootLayer),
                                  label: "PID",
                                  value: event.pid > 0 ? String(event.pid) : ""),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.process.frame, to: rootLayer),
                                  label: "Process",
                                  value: event.process),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.path.frame, to: rootLayer),
                                  label: "Path",
                                  value: event.path),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.detail.frame, to: rootLayer),
                                  label: "Detail",
                                  value: event.detail)
            ]
            rows.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                         role: .row,
                                         frame: rowsClipLayer.convert(row.container.frame, to: rootLayer),
                                         label: "\(event.time) \(event.type) \(event.pid) \(event.process) \(event.path) \(event.detail)",
                                         children: cells))
        }
        return accessibilityNode(nextIdentifier: &nextIdentifier,
                                 role: .table,
                                 frame: tableLayer.convert(rowsClipLayer.frame, to: rootLayer),
                                 label: "Firehose events",
                                 children: rows,
                                 rowCount: totalRows,
                                 columnCount: columns.count)
    }

    private func buildProcessTimelineAccessibilityNode(nextIdentifier: inout UInt32) -> OuterframeAccessibilityNode {
        var rows: [OuterframeAccessibilityNode] = []
        let visibleStart = processTimelineVisibleStartIndex()
        for (layerIndex, row) in timelineRowLayers.enumerated() where !row.container.isHidden {
            let processIndex = visibleStart + layerIndex
            guard let timelineRow = processTimelineRow(forGlobalIndex: processIndex) else { continue }
            let process = timelineRow.process
            let processName = process.process.isEmpty ? "pid-\(process.pid)" : process.process
            let label = "\(processName), pid \(process.pid), \(formatCount(Int(process.eventCount))) events"
            let cells = [
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.name.frame, to: rootLayer),
                                  label: "Process",
                                  value: processName),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.pid.frame, to: rootLayer),
                                  label: "PID",
                                  value: String(process.pid)),
                accessibilityNode(nextIdentifier: &nextIdentifier,
                                  role: .cell,
                                  frame: row.container.convert(row.events.frame, to: rootLayer),
                                  label: "Events",
                                  value: formatCount(Int(process.eventCount)))
            ]
            rows.append(accessibilityNode(nextIdentifier: &nextIdentifier,
                                         role: .row,
                                         frame: processTimelineRowsClipLayer.convert(row.container.frame, to: rootLayer),
                                         label: label,
                                         children: cells))
        }
        return accessibilityNode(nextIdentifier: &nextIdentifier,
                                 role: .table,
                                 frame: processTimelineLayer.frame,
                                 label: "Process timeline",
                                 children: rows,
                                 rowCount: processTimelineTotalRows,
                                 columnCount: 3)
    }

    private func accessibilityNode(nextIdentifier: inout UInt32,
                                   role: OuterframeAccessibilityRole,
                                   frame: CGRect,
                                   label: String? = nil,
                                   value: String? = nil,
                                   hint: String? = nil,
                                   children: [OuterframeAccessibilityNode] = [],
                                   rowCount: Int? = nil,
                                   columnCount: Int? = nil,
                                   isEnabled: Bool = true) -> OuterframeAccessibilityNode {
        let identifier = nextIdentifier
        nextIdentifier = nextIdentifier == UInt32.max ? 1 : nextIdentifier + 1
        return OuterframeAccessibilityNode(identifier: identifier,
                                           role: role,
                                           frame: frame,
                                           label: label,
                                           value: value,
                                           hint: hint,
                                           children: children,
                                           rowCount: rowCount,
                                           columnCount: columnCount,
                                           isEnabled: isEnabled)
    }

    private func notifyAccessibilityLayoutChanged() {
        guard didRegisterLayer, !accessibilityNotificationScheduled else { return }
        accessibilityNotificationScheduled = true
        Task { @MainActor in
            accessibilityNotificationScheduled = false
            outerframeHost.notifyAccessibilityTreeChanged(.layoutChanged)
        }
    }
}
