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

        #if DEBUG
        extensionHost.onMarketingDemo = { [weak self] in
            self?.startMarketingDemo()
        }
        #endif

        extensionHost.onDismissExtension = { [weak self] in
            self?.dismiss()
        }

        extensionHost.onCloseClassic = { [weak self] in
            self?.extensionHost.gameStore.stopMultiplayerSession()
            self?.dismiss()
        }

        extensionHost.onboardingDidComplete = { [weak self] in
            guard let self else { return }
            if let url = self.extensionHost.pendingGameURL {
                self.extensionHost.pendingGameURL = nil
                guard let conversation = self.activeConversation else {
                    self.extensionHost.route = .gameSelection
                    return
                }
                self.openGame(from: url, conversation: conversation)
            } else {
                self.extensionHost.route = .gameSelection
            }
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
        routeForConversation(conversation, allowDeferredSelection: true)
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        routeForConversation(conversation, allowDeferredSelection: true)
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        guard let url = message.url else { return }
        guard GameMessageURL.decode(from: url) != nil else { return }
        openGame(from: url, conversation: conversation)
    }

    private func routeForConversation(
        _ conversation: MSConversation,
        allowDeferredSelection: Bool
    ) {
        if let url = selectedGameURL(from: conversation) {
            openGame(from: url, conversation: conversation)
            return
        }
        guard allowDeferredSelection else {
            extensionHost.route = ProfileService.shared.loadLocal() == nil ? .onboarding : .gameSelection
            applyPresentationStyleForCurrentRoute()
            return
        }
        scheduleDeferredSelectionCheck(for: conversation)
    }

    private func selectedGameURL(from conversation: MSConversation) -> URL? {
        // Only the conversation's selected bubble — not last-sent/persisted URLs.
        // Bubble taps are handled by `didSelect`; this covers selectedMessage becoming available on activate.
        if let url = conversation.selectedMessage?.url, GameMessageURL.decode(from: url) != nil {
            return url
        }
        if let url = activeConversation?.selectedMessage?.url, GameMessageURL.decode(from: url) != nil {
            return url
        }
        return nil
    }

    private func scheduleDeferredSelectionCheck(for conversation: MSConversation) {
        pendingRouteWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak conversation] in
            guard let self, let conversation else { return }
            self.routeForConversation(conversation, allowDeferredSelection: false)
        }
        pendingRouteWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func openGame(from url: URL, conversation: MSConversation) {
        guard let gameState = GameStore.decode(from: url) else {
            extensionHost.route = .gameSelection
            applyPresentationStyleForCurrentRoute()
            return
        }
        guard ProfileService.shared.profile != nil else {
            extensionHost.pendingGameURL = url
            extensionHost.route = .onboarding
            applyPresentationStyleForCurrentRoute()
            return
        }
        extensionHost.gameStore.stopMultiplayerSession()
        extensionHost.gameStore.state = gameState
        extensionHost.gameStore.syncer = SupabaseSync()
        extensionHost.gameStore.isHost = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.extensionHost.gameStore.joinClassicRoom(
                    playerID: ProfileService.deviceID, name: Self.localPlayerName(for: conversation),
                    avatarIndex: ProfileService.shared.profile?.avatarIndex ?? 0
                )
                self.extensionHost.gameStore.subscribeToRoom()
                self.extensionHost.route = .game
                self.requestPresentationStyle(.expanded)
            } catch {
                self.extensionHost.route = .gameSelection
                self.presentGameConnectionError(error)
            }
        }
    }

    private static func localPlayerName(for conversation: MSConversation?) -> String {
        ProfileService.shared.profile?.displayName ?? "Player"
    }
    
    override func didResignActive(with conversation: MSConversation) {
        pendingRouteWorkItem?.cancel()
        pendingRouteWorkItem = nil
        extensionHost.pendingGameURL = nil
        extensionHost.gameStore.stopMultiplayerSession()
        extensionHost.route = ProfileService.shared.profile == nil ? .onboarding : .gameSelection
    }
   
    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        guard let url = message.url else { return }
        guard GameMessageURL.decode(from: url) != nil else { return }
        openGame(from: url, conversation: conversation)
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
        store.stopMultiplayerSession()
        store.state = GameStore.createNew(mode: .classicPoker)
        store.syncer = SupabaseSync()
        store.isHost = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await store.createClassicRoom(playerID: ProfileService.deviceID, name: Self.localPlayerName(for: conversation), avatarIndex: ProfileService.shared.profile?.avatarIndex ?? 0)
                store.subscribeToRoom()
                self.insertGameMessage(into: conversation, store: store)
            } catch {
                NSLog("Unable to create poker room: %@", error.localizedDescription)
                self.presentGameConnectionError(error)
            }
        }
    }

    private func presentGameConnectionError(_ error: Error) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let alert = UIAlertController(
            title: "Couldn’t start Classic Poker",
            message: "Please try again in a moment.\n\n\(detail)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func insertGameMessage(into conversation: MSConversation, store: GameStore) {
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
        conversation.insert(message) { [weak self] error in
            guard error == nil else { return }
            self?.dismiss()
        }
    }

    /// Local practice session — no iMessage bubble.
    private func startPracticeSession() {
        guard ProfileService.shared.profile != nil else {
            extensionHost.route = .onboarding
            applyPresentationStyleForCurrentRoute()
            return
        }
        let store = extensionHost.gameStore
        store.state = GameStore.createNew(mode: .practiceVsCPU)
        store.joinGame(
            playerID: Self.practiceLocalPlayerID,
            name: Self.localPlayerName(for: activeConversation)
        )
        extensionHost.route = .game
        requestPresentationStyle(.expanded)
    }

    private static let practiceLocalPlayerID = "practice-local"

    #if DEBUG
    private func startMarketingDemo() {
        extensionHost.route = .marketingDemo
        requestPresentationStyle(.expanded)
    }
    #endif

}

// MARK: - SwiftUI routing

@MainActor
private final class ExtensionHostModel: ObservableObject {
    enum Route {
        case onboarding
        case gameSelection
        case game
        #if DEBUG
        case marketingDemo
        #endif
    }

    @Published var route: Route = .gameSelection
    let gameStore: GameStore

    var pendingGameURL: URL?
    var onSendToChat: (() -> Void)?
    var onPracticePlay: (() -> Void)?
    #if DEBUG
    var onMarketingDemo: (() -> Void)?
    #endif
    var onDismissExtension: (() -> Void)?
    var onCloseClassic: (() -> Void)?
    var onboardingDidComplete: (() -> Void)?

    init(gameStore: GameStore) {
        self.gameStore = gameStore
    }

    var prefersExpandedPresentation: Bool {
        switch route {
        case .onboarding, .gameSelection, .game: return true
        #if DEBUG
        case .marketingDemo: return true
        #endif
        }
    }
}

private struct ExtensionShellView: View {
    @ObservedObject var model: ExtensionHostModel

    var body: some View {
        Group {
            switch model.route {
            case .onboarding:
                OnboardingView {
                    model.onboardingDidComplete?()
                }
            case .gameSelection:
                GameSelectionView(
                    onClassicSend: { model.onSendToChat?() ?? () },
                    onPracticePlay: { model.onPracticePlay?() ?? () },
                    onMarketingDemo: {
                        #if DEBUG
                        model.onMarketingDemo?()
                        #endif
                    }
                )
            case .game:
                RootView(
                    onExitPractice: { model.onDismissExtension?() },
                    onExitClassic: { model.onCloseClassic?() }
                )
                .environmentObject(model.gameStore)
            #if DEBUG
            case .marketingDemo:
                MarketingDemoView()
            #endif
            }
        }
    }
}
