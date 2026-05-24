//
//  MessagesViewController.swift
//  Poker MessagesExtension
//
//  Created by Pranav Thoppe on 5/11/26.
//

import UIKit
import Messages
import SwiftUI
import Combine
import os

// MARK: - Route debug (filter Xcode console: "PokerRoute")

private enum RouteDebug {
    private static let log = Logger(subsystem: "com.poker.messages", category: "PokerRoute")

    static func event(_ name: String, _ details: String = "") {
        let line = details.isEmpty ? "[PokerRoute] \(name)" : "[PokerRoute] \(name) | \(details)"
        log.info("\(line, privacy: .public)")
        NSLog("%@", line)
    }

    static func messageContext(
        label: String,
        conversation: MSConversation,
        message: MSMessage?,
        activeConversation: MSConversation?
    ) {
        let convURL = conversation.selectedMessage?.url?.absoluteString ?? "nil"
        let activeURL = activeConversation?.selectedMessage?.url?.absoluteString ?? "nil"
        let msgURL = message?.url?.absoluteString ?? "nil"
        let convDecode = conversation.selectedMessage?.url.flatMap { GameMessageURL.decode(from: $0) } != nil
        let activeDecode = activeConversation?.selectedMessage?.url.flatMap { GameMessageURL.decode(from: $0) } != nil
        let msgDecode = message?.url.flatMap { GameMessageURL.decode(from: $0) } != nil
        event(
            label,
            """
            conv.selectedMessage.url=\(convURL) decodeOK=\(convDecode) \
            active.selectedMessage.url=\(activeURL) decodeOK=\(activeDecode) \
            message.url=\(msgURL) decodeOK=\(msgDecode)
            """
        )
    }
}

class MessagesViewController: MSMessagesAppViewController {

    private let extensionHost: ExtensionHostModel
    private var pendingRouteWorkItem: DispatchWorkItem?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        extensionHost = ExtensionHostModel(gameStore: GameStore())
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        extensionHost = ExtensionHostModel(gameStore: GameStore())
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        extensionHost.onSendToChat = { [weak self] in
            self?.sendGameMessage(to: self?.activeConversation)
        }

        extensionHost.onPracticePlay = { [weak self] in
            self?.startPracticeSession()
        }

        let shell = ExtensionShellView(model: extensionHost)
        let host = UIHostingController(rootView: shell)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .black
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
    
    // MARK: - Conversation Handling
    
    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        RouteDebug.messageContext(
            label: "willBecomeActive",
            conversation: conversation,
            message: nil,
            activeConversation: activeConversation
        )
        routeForConversation(conversation, allowDeferredSelection: true, source: "willBecomeActive")
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        RouteDebug.messageContext(
            label: "didBecomeActive",
            conversation: conversation,
            message: nil,
            activeConversation: activeConversation
        )
        routeForConversation(conversation, allowDeferredSelection: true, source: "didBecomeActive")
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        RouteDebug.messageContext(
            label: "didSelect",
            conversation: conversation,
            message: message,
            activeConversation: activeConversation
        )
        guard let url = message.url else {
            RouteDebug.event("didSelect", "no message.url → skip openGame")
            return
        }
        if GameMessageURL.decode(from: url) == nil {
            RouteDebug.event("didSelect", "url not poker game: \(url.absoluteString)")
            return
        }
        openGame(from: url, conversation: conversation, source: "didSelect")
    }

    private func routeForConversation(
        _ conversation: MSConversation,
        allowDeferredSelection: Bool,
        source: String
    ) {
        RouteDebug.event(
            "routeForConversation",
            "source=\(source) allowDeferred=\(allowDeferredSelection) currentRoute=\(extensionHost.route)"
        )
        if let url = selectedGameURL(from: conversation, source: source) {
            openGame(from: url, conversation: conversation, source: source)
            return
        }
        guard allowDeferredSelection else {
            RouteDebug.event("routeForConversation", "source=\(source) → fallback gameSelection (no URL after defer)")
            extensionHost.route = .gameSelection
            applyPresentationStyleForCurrentRoute()
            return
        }
        RouteDebug.event("routeForConversation", "source=\(source) → scheduling deferred selection check")
        scheduleDeferredSelectionCheck(for: conversation)
    }

    private func selectedGameURL(from conversation: MSConversation, source: String) -> URL? {
        // Only the conversation's selected bubble — not last-sent/persisted URLs.
        // Bubble taps are handled by `didSelect`; this covers selectedMessage becoming available on activate.
        if let url = conversation.selectedMessage?.url, GameMessageURL.decode(from: url) != nil {
            RouteDebug.event("selectedGameURL", "source=\(source) hit=conversation.selectedMessage url=\(url.absoluteString)")
            return url
        }
        if let url = activeConversation?.selectedMessage?.url, GameMessageURL.decode(from: url) != nil {
            RouteDebug.event("selectedGameURL", "source=\(source) hit=activeConversation.selectedMessage url=\(url.absoluteString)")
            return url
        }
        RouteDebug.event("selectedGameURL", "source=\(source) no selected poker bubble")
        return nil
    }

    private func scheduleDeferredSelectionCheck(for conversation: MSConversation) {
        pendingRouteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak conversation] in
            guard let self, let conversation else {
                RouteDebug.event("deferredCheck", "self or conversation deallocated")
                return
            }
            RouteDebug.messageContext(
                label: "deferredCheck",
                conversation: conversation,
                message: nil,
                activeConversation: self.activeConversation
            )
            self.routeForConversation(conversation, allowDeferredSelection: false, source: "deferredCheck")
        }
        pendingRouteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func openGame(from url: URL, conversation: MSConversation, source: String) {
        guard let gameState = GameStore.decode(from: url) else {
            RouteDebug.event("openGame", "source=\(source) GameStore.decode failed url=\(url.absoluteString) → gameSelection")
            extensionHost.route = .gameSelection
            applyPresentationStyleForCurrentRoute()
            return
        }
        let localID = conversation.localParticipantIdentifier.uuidString
        extensionHost.gameStore.state = gameState
        extensionHost.gameStore.joinGame(
            playerID: localID,
            name: Self.localPlayerName(for: conversation)
        )
        extensionHost.route = .game
        RouteDebug.event(
            "openGame",
            "source=\(source) SUCCESS gameID=\(gameState.gameID) phase=\(gameState.phase) players=\(extensionHost.gameStore.state.players.count) route=game"
        )
        requestPresentationStyle(.expanded)
    }

    private static func localPlayerName(for conversation: MSConversation?) -> String {
        // Onboarding / display names deferred; use a stable placeholder per device.
        "Player"
    }
    
    override func didResignActive(with conversation: MSConversation) {
        pendingRouteWorkItem?.cancel()
        pendingRouteWorkItem = nil
        extensionHost.route = .gameSelection
        RouteDebug.event("didResignActive", "route=gameSelection")
    }
   
    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        RouteDebug.messageContext(
            label: "didReceive",
            conversation: conversation,
            message: message,
            activeConversation: activeConversation
        )
        guard let url = message.url else {
            RouteDebug.event("didReceive", "no message.url")
            return
        }
        guard GameMessageURL.decode(from: url) != nil else {
            RouteDebug.event("didReceive", "not poker url: \(url.absoluteString)")
            return
        }
        openGame(from: url, conversation: conversation, source: "didReceive")
    }
    
    
    override func willTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.willTransition(to: presentationStyle)
        guard presentationStyle == .compact, extensionHost.prefersExpandedPresentation else { return }
        requestPresentationStyle(.expanded)
    }
    
    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
    }

    private func applyPresentationStyleForCurrentRoute() {
        guard extensionHost.prefersExpandedPresentation else { return }
        requestPresentationStyle(.expanded)
    }

    // MARK: - Game invite

    /// Sends a Classic Poker bubble: template layout shows only the card image (no caption strip).
    private func sendGameMessage(to conversation: MSConversation?) {
        guard let conversation else { return }

        let store = extensionHost.gameStore
        store.state = GameStore.createNew(mode: .classicPoker)
        store.joinGame(
            playerID: conversation.localParticipantIdentifier.uuidString,
            name: Self.localPlayerName(for: conversation)
        )

        let message = MSMessage()
        let layout = MSMessageTemplateLayout()
        layout.caption = nil
        layout.subcaption = nil
        layout.trailingCaption = nil
        layout.trailingSubcaption = nil
        layout.imageTitle = nil
        layout.imageSubtitle = nil
        layout.image = UIImage(named: "BubbleCard")
        message.layout = layout
        message.url = GameMessageURL.encode(gameID: store.state.gameID, phase: store.state.phase)
        RouteDebug.event(
            "sendGameMessage",
            "insert url=\(message.url?.absoluteString ?? "nil") gameID=\(store.state.gameID)"
        )
        conversation.insert(message) { [weak self] error in
            if let error {
                RouteDebug.event("sendGameMessage", "insert failed: \(error.localizedDescription)")
                return
            }
            RouteDebug.event("sendGameMessage", "insert OK → dismiss")
            self?.dismiss()
        }
    }

    /// Local practice session — no iMessage bubble.
    private func startPracticeSession() {
        let store = extensionHost.gameStore
        store.state = GameStore.createNew(mode: .practiceVsCPU)
        store.joinGame(
            playerID: Self.practiceLocalPlayerID,
            name: Self.localPlayerName(for: activeConversation)
        )
        extensionHost.route = .game
        RouteDebug.event(
            "startPracticeSession",
            "gameID=\(store.state.gameID) gameMode=\(store.state.gameMode.rawValue) route=game"
        )
        requestPresentationStyle(.expanded)
    }

    private static let practiceLocalPlayerID = "practice-local"

}

// MARK: - SwiftUI routing

@MainActor
private final class ExtensionHostModel: ObservableObject {
    enum Route {
        case gameSelection
        case game
    }

    @Published var route: Route = .gameSelection
    let gameStore: GameStore

    var onSendToChat: (() -> Void)?
    var onPracticePlay: (() -> Void)?

    init(gameStore: GameStore) {
        self.gameStore = gameStore
    }

    var prefersExpandedPresentation: Bool {
        switch route {
        case .gameSelection, .game: return true
        }
    }
}

private struct ExtensionShellView: View {
    @ObservedObject var model: ExtensionHostModel

    var body: some View {
        Group {
            switch model.route {
            case .gameSelection:
                GameSelectionView(
                    onClassicSend: { model.onSendToChat?() ?? () },
                    onPracticePlay: { model.onPracticePlay?() ?? () }
                )
            case .game:
                RootView().environmentObject(model.gameStore)
            }
        }
    }
}
