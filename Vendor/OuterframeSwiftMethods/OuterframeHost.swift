//
//  OuterframeHost.swift
//  OuterframeSwiftMethods
//
//  Method-based API for browser communication, wrapping the socket protocol.
//

import AppKit
import Foundation
import Network
import QuartzCore

enum OuterframeHostError: LocalizedError {
    case apiFailure(String)

    var errorDescription: String? {
        switch self {
        case .apiFailure(let methodName):
            return "Missing method, the API may have changed: \(methodName)"
        }
    }
}

typealias OuterframeHostMessageHandler = @MainActor (OuterframeHost, BrowserToContentMessage) -> Void
typealias OuterframeHostDisconnectHandler = @MainActor (OuterframeHost) -> Void

/// Delegate for receiving decoded messages from the browser.
@MainActor
protocol OuterframeHostDelegate: AnyObject {
    /// Called when a message is received from the browser.
    /// Note: displayLinkFired and displayLinkCallbackRegistered
    /// are handled internally by OuterframeHost and will not be forwarded to this delegate.
    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage)

    /// Called when the connection to the browser is closed.
    func outerframeHostDidDisconnect(_ host: OuterframeHost)
}

/// Helper class providing method-based API for browser communication
@MainActor
final class OuterframeHost: SocketToBrowserDelegate {
    let socket: SocketToBrowser

    /// Delegate for receiving decoded messages from the browser.
    weak var delegate: OuterframeHostDelegate?
    private var messageHandler: OuterframeHostMessageHandler?
    private var disconnectHandler: OuterframeHostDisconnectHandler?

    /// The URL that was navigated to (e.g., "https://example.com/apps/top.outer?host=server1")
    private var _url: String?

    /// The URL where the plugin bundle was downloaded from
    private var _bundleUrl: String?

    private var _currentHistoryEntryID: UUID?
    private var _historyLength: UInt32 = 0
    private var _canGoBack = false
    private var _canGoForward = false

    // Display link callback management
    private var displayLinkCallbacks: [UUID: @MainActor @Sendable (CFTimeInterval) -> Void] = [:]
    private var pendingDisplayLinkCallbacks: [UUID: @MainActor @Sendable (CFTimeInterval) -> Void] = [:]
    private var callbackIDToBrowserID: [UUID: UUID] = [:]
    private var browserIDToCallbackID: [UUID: UUID] = [:]

    /// Creates an OuterframeHost and starts the socket.
    /// Call `configure()` after receiving the initializeContent message to set context and appearance.
    init(socketFD: Int32,
         messageHandler: OuterframeHostMessageHandler? = nil,
         disconnectHandler: OuterframeHostDisconnectHandler? = nil) {
        let socket = SocketToBrowser()
        self.socket = socket
        self._url = nil
        self._bundleUrl = nil
        self.messageHandler = messageHandler
        self.disconnectHandler = disconnectHandler

        // Set ourselves as the socket delegate to decode messages
        socket.delegate = self

        // Start the socket for plugin communication
        Task {
            await socket.start(withFileDescriptor: socketFD)
        }
    }

    // MARK: - SocketToBrowserDelegate

    nonisolated func socketToBrowser(_ socket: SocketToBrowser, didReceiveMessage message: Data) {
        Task { @MainActor in
            handleRawMessage(messageData: message)
        }
    }

    nonisolated func socketToBrowserDidClose(_ socket: SocketToBrowser) {
        Task { @MainActor in
            if let disconnectHandler {
                disconnectHandler(self)
            } else {
                delegate?.outerframeHostDidDisconnect(self)
            }
        }
    }

    func setMessageHandler(_ handler: OuterframeHostMessageHandler?) {
        messageHandler = handler
    }

    func setDisconnectHandler(_ handler: OuterframeHostDisconnectHandler?) {
        disconnectHandler = handler
    }

    private func handleRawMessage(messageData: Data) {
        let message: BrowserToContentMessage
        do {
            message = try BrowserToContentMessage.decode(message: messageData)
        } catch {
            print("OuterframeHost: Failed to decode message: \(error)")
            return
        }

        // Handle internal messages that OuterframeHost manages
        switch message {
        case .displayLinkFired(_, let targetTimestamp):
            handleDisplayLinkFired(targetTimestamp: targetTimestamp)
            return

        case .displayLinkCallbackRegistered(let callbackID, let browserCallbackID):
            handleDisplayLinkCallbackRegistered(callbackID: callbackID, browserCallbackID: browserCallbackID)
            return
        case .initializeContent(let arguments):
            _currentHistoryEntryID = arguments.historyEntryID

        case .historyEntryAccepted(let entryID, let url),
             .historyTraversal(let entryID, let url):
            _currentHistoryEntryID = entryID
            _url = url

        case .historyContextUpdate(let currentEntryID, let url, let length, let canGoBack, let canGoForward):
            _currentHistoryEntryID = currentEntryID
            _url = url
            _historyLength = length
            _canGoBack = canGoBack
            _canGoForward = canGoForward

        default:
            break
        }

        if let messageHandler {
            messageHandler(self, message)
        } else {
            delegate?.outerframeHost(self, didReceiveMessage: message)
        }
    }

    /// Configures the host with data from the initializeContent message.
    func configure(url: String,
                   bundleUrl: String,
                   proxyHost: String?,
                   proxyPort: UInt16,
                   proxyUsername: String?,
                   proxyPassword: String?) {
        self._url = url
        self._bundleUrl = bundleUrl
        self._networkProxyHost = proxyHost
        self._networkProxyPort = proxyPort
        self._networkProxyUsername = proxyUsername
        self._networkProxyPassword = proxyPassword
    }

    // MARK: - Cursor

    func setCursor(_ cursorType: PluginCursorType) {
        Task {
            try? await socket.send(ContentToBrowserMessage.cursorUpdate(cursorType: UInt8(cursorType.rawValue)).encode())
        }
    }

    // MARK: - Input Mode

    func setInputMode(_ inputMode: OuterframeContentInputMode) {
        Task {
            try? await socket.send(ContentToBrowserMessage.inputModeUpdate(inputMode: inputMode.rawValue).encode())
        }
    }

    // MARK: - Pasteboard Capabilities

    func setPasteboardCapabilities(_ capabilities: OuterframeContentEditingCapabilities) {
        Task {
            try? await socket.send(ContentToBrowserMessage.setPasteboardCapabilities(
                canCopy: capabilities.canCopy,
                canCut: capabilities.canCut,
                pasteboardTypes: capabilities.acceptablePasteboardTypeIdentifiers
            ).encode())
        }
    }

    // MARK: - Display Link

    func registerDisplayLinkCallback(_ callback: @MainActor @Sendable @escaping (CFTimeInterval) -> Void) -> UUID {
        let callbackID = UUID()
        pendingDisplayLinkCallbacks[callbackID] = callback

        Task {
            try? await socket.send(ContentToBrowserMessage.startDisplayLink(callbackID: callbackID).encode())
        }

        return callbackID
    }

    func stopDisplayLinkCallback(_ callbackID: UUID) {
        pendingDisplayLinkCallbacks.removeValue(forKey: callbackID)
        displayLinkCallbacks.removeValue(forKey: callbackID)

        if let browserID = callbackIDToBrowserID.removeValue(forKey: callbackID) {
            browserIDToCallbackID.removeValue(forKey: browserID)
            Task {
                try? await socket.send(ContentToBrowserMessage.stopDisplayLink(browserCallbackID: browserID).encode())
            }
        }
    }

    private func handleDisplayLinkCallbackRegistered(callbackID: UUID, browserCallbackID: UUID) {
        callbackIDToBrowserID[callbackID] = browserCallbackID
        browserIDToCallbackID[browserCallbackID] = callbackID

        if let callback = pendingDisplayLinkCallbacks.removeValue(forKey: callbackID) {
            displayLinkCallbacks[callbackID] = callback
        }
    }

    private func handleDisplayLinkFired(targetTimestamp: Double) {
        for callback in displayLinkCallbacks.values {
            callback(targetTimestamp)
        }
    }

    // MARK: - Text Cursor

    func sendTextCursorUpdate(cursors: [OuterContentTextCursorSnapshot]) {
        Task {
            try? await socket.send(ContentToBrowserMessage.textCursorUpdate(cursors: cursors).encode())
        }
    }

    // MARK: - Navigation

    func openNewWindow(with url: URL, displayString: String?, preferredSize: CGSize?) {
        Task {
            try? await socket.send(ContentToBrowserMessage.openNewWindow(
                url: url.absoluteString,
                displayString: displayString,
                preferredSize: preferredSize
            ).encode())
        }
    }

    @discardableResult
    func pushHistoryEntry(url: URL?) -> UUID {
        let entryID = UUID()
        Task {
            try? await socket.send(ContentToBrowserMessage.historyPushEntry(
                entryID: entryID,
                url: url?.absoluteString
            ).encode())
        }
        return entryID
    }

    @discardableResult
    func replaceHistoryEntry(url: URL?) -> UUID {
        let entryID = UUID()
        Task {
            try? await socket.send(ContentToBrowserMessage.historyReplaceEntry(
                entryID: entryID,
                url: url?.absoluteString
            ).encode())
        }
        return entryID
    }

    func goInHistory(by delta: Int32) {
        Task {
            try? await socket.send(ContentToBrowserMessage.historyGo(delta: delta).encode())
        }
    }

    func goBackInHistory() {
        goInHistory(by: -1)
    }

    func goForwardInHistory() {
        goInHistory(by: 1)
    }

    func showContextMenu(for attributedText: NSAttributedString, at location: CGPoint) {
        guard let data = try? attributedText.data(from: NSRange(location: 0, length: attributedText.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            return
        }
        Task {
            try? await socket.send(ContentToBrowserMessage.showContextMenu(
                attributedTextData: data,
                locationX: location.x,
                locationY: location.y
            ).encode())
        }
    }

    func showContextMenu(menuID: UUID, items: [OuterframeContextMenuItem], at location: CGPoint) {
        Task {
            try? await socket.send(ContentToBrowserMessage.showContextMenuItems(
                menuID: menuID,
                locationX: location.x,
                locationY: location.y,
                items: items
            ).encode())
        }
    }

    func showDefinition(for attributedText: NSAttributedString, at location: CGPoint) {
        guard let data = try? attributedText.data(from: NSRange(location: 0, length: attributedText.length),
                                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
            return
        }
        Task {
            try? await socket.send(ContentToBrowserMessage.showDefinition(
                attributedTextData: data,
                locationX: location.x,
                locationY: location.y
            ).encode())
        }
    }

    // MARK: - Haptic Feedback

    func performHapticFeedback(_ style: OuterframeHapticFeedbackStyle) {
        Task {
            try? await socket.send(ContentToBrowserMessage.hapticFeedback(style: UInt8(style.rawValue)).encode())
        }
    }

    func sendAccessibilitySnapshotResponse(requestID: UUID, snapshotData: Data?) {
        Task {
            try? await socket.send(ContentToBrowserMessage.accessibilitySnapshotResponse(
                requestID: requestID,
                snapshotData: snapshotData
            ).encode())
        }
    }

    func sendAccessibilitySnapshotResponse(requestID: UUID, snapshot: OuterframeAccessibilitySnapshot?) {
        sendAccessibilitySnapshotResponse(
            requestID: requestID,
            snapshotData: (snapshot ?? OuterframeAccessibilitySnapshot.notImplementedSnapshot()).serializedData()
        )
    }

    // MARK: - Pasteboard

    /// Sends a copy selected pasteboard response to the browser.
    func sendCopySelectedPasteboardResponse(requestID: UUID, items: [OuterContentPasteboardItem]) {
        Task {
            try? await socket.send(ContentToBrowserMessage.copySelectedPasteboardResponse(
                requestID: requestID,
                items: items
            ).encode())
        }
    }

    // MARK: - Context URLs

    /// The full URL that was navigated to.
    func pluginURL() -> URL? {
        guard let urlString = _url else { return nil }
        return URL(string: urlString)
    }

    /// The security origin (scheme + host + port).
    func pluginOriginURL() -> URL? {
        guard let url = pluginURL(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The directory containing the .outer file.
    func pluginBaseURL() -> URL? {
        pluginURL()?.deletingLastPathComponent()
    }

    /// The URL where the plugin bundle was downloaded from.
    func pluginBundleURL() -> URL? {
        guard let urlString = _bundleUrl else { return nil }
        return URL(string: urlString)
    }

    func currentHistoryEntryID() -> UUID? {
        _currentHistoryEntryID
    }

    func historyLength() -> UInt32 {
        _historyLength
    }

    func canGoBackInHistory() -> Bool {
        _canGoBack
    }

    func canGoForwardInHistory() -> Bool {
        _canGoForward
    }

    // MARK: - Network Proxy (stored separately, set by host before passing to plugin)

    private var _networkProxyHost: String?
    private var _networkProxyPort: UInt16 = 0
    private var _networkProxyUsername: String?
    private var _networkProxyPassword: String?

    func networkProxyConfiguration() -> (host: String, port: UInt16, username: String, password: String)? {
        guard let host = _networkProxyHost,
              let username = _networkProxyUsername,
              let password = _networkProxyPassword else {
            return nil
        }
        return (host, _networkProxyPort, username, password)
    }

    func applyProxy(to configuration: URLSessionConfiguration) {
        guard let proxy = networkProxyConfiguration(),
              !proxy.host.isEmpty,
              proxy.port != 0,
              let endpointPort = NWEndpoint.Port(rawValue: proxy.port) else {
            return
        }

        var socksProxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(proxy.host),
                                                                    port: endpointPort))
        socksProxy.applyCredential(username: proxy.username, password: proxy.password)
        socksProxy.allowFailover = false
        socksProxy.excludedDomains = []
        socksProxy.matchDomains = [""]
        configuration.proxyConfigurations = [socksProxy]
    }
}

/// Cursor types that plugins can request
enum PluginCursorType: Int {
    case arrow = 0
    case iBeam = 1
    case crosshair = 2
    case openHand = 3
    case closedHand = 4
    case pointingHand = 5
    case resizeLeft = 6
    case resizeRight = 7
    case resizeLeftRight = 8
    case resizeUp = 9
    case resizeDown = 10
    case resizeUpDown = 11
}

enum OuterframeHapticFeedbackStyle: Int {
    case generic = 0
    case alignment = 1
    case levelChange = 2
}

/// Input modes that plugins can request. Represented as a bitmask so modes can be combined.
struct OuterframeContentInputMode: OptionSet, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let textInput = OuterframeContentInputMode(rawValue: 1 << 0)   // Keyboard events interpreted as text
    static let rawKeys = OuterframeContentInputMode(rawValue: 1 << 1)     // Raw key events forwarded to the plugin
    static let none: OuterframeContentInputMode = []

    var allowsTextInput: Bool { contains(.textInput) }
    var allowsRawKeys: Bool { contains(.rawKeys) }
}

/// Describes whether the plugin can currently satisfy copy/paste commands.
struct OuterframeContentEditingCapabilities: Sendable {
    var canCopy: Bool
    var canCut: Bool
    var acceptablePasteboardTypeIdentifiers: [String]

    init(canCopy: Bool,
         canCut: Bool,
         acceptablePasteboardTypeIdentifiers: [String]) {
        self.canCopy = canCopy
        self.canCut = canCut
        self.acceptablePasteboardTypeIdentifiers = acceptablePasteboardTypeIdentifiers
    }
}
