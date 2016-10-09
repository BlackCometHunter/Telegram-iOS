import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import Display
import AsyncDisplayKit
import TelegramCore

public class ChatController: ViewController {
    private var containerLayout = ContainerViewLayout()
    
    private let account: Account
    private let peerId: PeerId
    private let messageId: MessageId?
    
    private let peerDisposable = MetaDisposable()
    private let navigationActionDisposable = MetaDisposable()
    
    private let messageIndexDisposable = MetaDisposable()
    
    private let _peerReady = Promise<Bool>()
    private var didSetPeerReady = false
    private let peerView = Promise<PeerView>()
    
    private var presentationInterfaceState = ChatPresentationInterfaceState(interfaceState: ChatInterfaceState(), peer: nil, inputContext: nil)
    private let chatInterfaceStatePromise = Promise<ChatInterfaceState>()
    
    private var chatTitleView: ChatTitleView?
    private var leftNavigationButton: ChatNavigationButton?
    private var rightNavigationButton: ChatNavigationButton?
    private var chatInfoNavigationButton: ChatNavigationButton?
    
    private let galleryHiddenMesageAndMediaDisposable = MetaDisposable()
    
    private var controllerInteraction: ChatControllerInteraction?
    private var interfaceInteraction: ChatPanelInterfaceInteraction?
    
    public init(account: Account, peerId: PeerId, messageId: MessageId? = nil) {
        self.account = account
        self.peerId = peerId
        self.messageId = messageId
        
        super.init()
        
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "Back", style: .plain, target: nil, action: nil)
        
        self.ready.set(.never())
        
        self.scrollToTop = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                strongSelf.chatDisplayNode.historyNode.scrollToStartOfHistory()
            }
        }
        
        let controllerInteraction = ChatControllerInteraction(openMessage: { [weak self] id in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                var galleryMedia: Media?
                if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(id) {
                    for media in message.media {
                        if let file = media as? TelegramMediaFile {
                            galleryMedia = file
                        } else if let image = media as? TelegramMediaImage {
                            galleryMedia = image
                        } else if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content {
                            if let file = content.file {
                                galleryMedia = file
                            } else if let image = content.image {
                                galleryMedia = image
                            }
                        }
                    }
                }
                
                if let galleryMedia = galleryMedia {
                    if let file = galleryMedia as? TelegramMediaFile, file.mimeType == "audio/mpeg" {
                        //debugPlayMedia(account: strongSelf.account, file: file)
                    } else {
                        let gallery = GalleryController(account: strongSelf.account, messageId: id)
                        
                        strongSelf.galleryHiddenMesageAndMediaDisposable.set(gallery.hiddenMedia.start(next: { [weak strongSelf] messageIdAndMedia in
                            if let strongSelf = strongSelf {
                                if let messageIdAndMedia = messageIdAndMedia {
                                    strongSelf.controllerInteraction?.hiddenMedia = [messageIdAndMedia.0: [messageIdAndMedia.1]]
                                } else {
                                    strongSelf.controllerInteraction?.hiddenMedia = [:]
                                }
                                strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                    if let itemNode = itemNode as? ChatMessageItemView {
                                        itemNode.updateHiddenMedia()
                                    }
                                }
                            }
                        }))
                        
                        strongSelf.present(gallery, in: .window, with: GalleryControllerPresentationArguments(transitionArguments: { [weak self] messageId, media in
                            if let strongSelf = self {
                                var transitionNode: ASDisplayNode?
                                strongSelf.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                                    if let itemNode = itemNode as? ChatMessageItemView {
                                        if let result = itemNode.transitionNode(id: messageId, media: media) {
                                            transitionNode = result
                                        }
                                    }
                                }
                                if let transitionNode = transitionNode {
                                    return GalleryTransitionArguments(transitionNode: transitionNode, transitionContainerNode: strongSelf.chatDisplayNode, transitionBackgroundNode: strongSelf.chatDisplayNode.historyNode)
                                }
                            }
                            return nil
                        }))
                    }
                }
            }
        }, openPeer: { [weak self] id, navigation in
            if let strongSelf = self {
                (strongSelf.navigationController as? NavigationController)?.pushViewController(ChatController(account: strongSelf.account, peerId: id, messageId: nil))
            }
        }, openMessageContextMenu: { [weak self] id, node, frame in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(id) {
                    if let contextMenuController = contextMenuForChatPresentationIntefaceState(strongSelf.presentationInterfaceState, account: strongSelf.account, message: message, interfaceInteraction: strongSelf.interfaceInteraction) {
                        strongSelf.present(contextMenuController, in: .window, with: ContextMenuControllerPresentationArguments(sourceNodeAndRect: { [weak strongSelf, weak node] in
                            if let node = node {
                                return (node, frame)
                            } else {
                                return nil
                            }
                        }))
                    }
                }
            }
        }, navigateToMessage: { [weak self] fromId, id in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                if id.peerId == strongSelf.peerId {
                    var fromIndex: MessageIndex?
                    
                    if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(fromId) {
                        fromIndex = MessageIndex(message)
                    }
                    
                    if let fromIndex = fromIndex {
                        if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(id) {
                            strongSelf.chatDisplayNode.historyNode.scrollToMessage(from: fromIndex, to: MessageIndex(message))
                        } else {
                            strongSelf.messageIndexDisposable.set((strongSelf.account.postbox.messageIndexAtId(id) |> deliverOnMainQueue).start(next: { [weak strongSelf] index in
                                if let strongSelf = strongSelf, let index = index {
                                    strongSelf.chatDisplayNode.historyNode.scrollToMessage(from: fromIndex, to: index)
                                }
                            }))
                        }
                    }
                } else {
                    (strongSelf.navigationController as? NavigationController)?.pushViewController(ChatController(account: strongSelf.account, peerId: id.peerId, messageId: id))
                }
            }
        }, clickThroughMessage: { [weak self] in
            self?.view.endEditing(true)
        }, toggleMessageSelection: { [weak self] id in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(id) {
                    strongSelf.updateChatPresentationInterfaceState(animated: false, { $0.updatedInterfaceState { $0.withToggledSelectedMessage(id) } })
                }
            }
        })
        
        self.controllerInteraction = controllerInteraction
        
        self.chatTitleView = ChatTitleView(frame: CGRect())
        self.navigationItem.titleView = self.chatTitleView
        
        let chatInfoButtonItem = UIBarButtonItem(customDisplayNode: ChatAvatarNavigationNode())!
        chatInfoButtonItem.target = self
        chatInfoButtonItem.action = #selector(self.rightNavigationButtonAction)
        self.chatInfoNavigationButton = ChatNavigationButton(action: .openChatInfo, buttonItem: chatInfoButtonItem)
        
        self.updateChatPresentationInterfaceState(animated: false, { return $0 })
        
        self.peerView.set(account.viewTracker.peerView(peerId))
        
        peerDisposable.set((self.peerView.get()
            |> deliverOnMainQueue).start(next: { [weak self] peerView in
                if let strongSelf = self {
                    if let peer = peerView.peers[peerId] {
                        strongSelf.chatTitleView?.peerView = peerView
                        (strongSelf.chatInfoNavigationButton?.buttonItem.customDisplayNode as? ChatAvatarNavigationNode)?.avatarNode.setPeer(account: strongSelf.account, peer: peer)
                    }
                    strongSelf.updateChatPresentationInterfaceState(animated: false, { return $0.updatedPeer { _ in return peerView.peers[peerId] } })
                    if !strongSelf.didSetPeerReady {
                        strongSelf.didSetPeerReady = true
                        strongSelf._peerReady.set(.single(true))
                    }
                }
            }))
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.messageIndexDisposable.dispose()
        self.navigationActionDisposable.dispose()
        self.galleryHiddenMesageAndMediaDisposable.dispose()
        self.peerDisposable.dispose()
    }
    
    var chatDisplayNode: ChatControllerNode {
        get {
            return super.displayNode as! ChatControllerNode
        }
    }
    
    override public func loadDisplayNode() {
        self.displayNode = ChatControllerNode(account: self.account, peerId: self.peerId, messageId: self.messageId, controllerInteraction: self.controllerInteraction!)
        
        self.ready.set(combineLatest(self.chatDisplayNode.historyNode.historyReady.get(), self._peerReady.get()) |> map { $0 && $1 })
        
        self.chatDisplayNode.historyNode.visibleContentOffsetChanged = { [weak self] offset in
            if let strongSelf = self {
                let offsetAlpha: CGFloat
                switch offset {
                    case let .known(offset):
                        if offset < 40.0 {
                            offsetAlpha = 0.0
                        } else {
                            offsetAlpha = 1.0
                        }
                    case .unknown:
                        offsetAlpha = 1.0
                    case .none:
                        offsetAlpha = 0.0
                }
                
                if !strongSelf.chatDisplayNode.navigateToLatestButton.alpha.isEqual(to: offsetAlpha) {
                    UIView.animate(withDuration: 0.2, delay: 0.0, options: [.beginFromCurrentState], animations: {
                        strongSelf.chatDisplayNode.navigateToLatestButton.alpha = offsetAlpha
                    }, completion: nil)
                }
            }
        }
        
        self.chatDisplayNode.requestLayout = { [weak self] transition in
            self?.requestLayout(transition: transition)
        }
        
        self.chatDisplayNode.setupSendActionOnViewUpdate = { [weak self] f in
            self?.chatDisplayNode.historyNode.layoutActionOnViewTransition = { [weak self] transition in
                f()
                if let strongSelf = self {
                    var mappedTransition: (ChatHistoryListViewTransition, ListViewUpdateSizeAndInsets?)?
                    
                    strongSelf.chatDisplayNode.containerLayoutUpdated(strongSelf.containerLayout, navigationBarHeight: strongSelf.navigationBar.frame.maxY, transition: .animated(duration: 0.4, curve: .spring), listViewTransaction: { updateSizeAndInsets in
                        var options = transition.options
                        let _ = options.insert(.Synchronous)
                        let _ = options.insert(.LowLatency)
                        options.remove(.AnimateInsertion)
                        
                        let deleteItems = transition.deleteItems.map({ item in
                            return ListViewDeleteItem(index: item.index, directionHint: nil)
                        })
                        
                        var maxInsertedItem: Int?
                        var insertItems: [ListViewInsertItem] = []
                        for i in 0 ..< transition.insertItems.count {
                            let item = transition.insertItems[i]
                            if item.directionHint == .Down && (maxInsertedItem == nil || maxInsertedItem! < item.index) {
                                maxInsertedItem = item.index
                            }
                            insertItems.append(ListViewInsertItem(index: item.index, previousIndex: item.previousIndex, item: item.item, directionHint: item.directionHint == .Down ? .Up : nil))
                        }
                        
                        let scrollToItem = ListViewScrollToItem(index: 0, position: .Top, animated: true, curve: .Spring(duration: 0.4), directionHint: .Up)
                        
                        var stationaryItemRange: (Int, Int)?
                        if let maxInsertedItem = maxInsertedItem {
                            stationaryItemRange = (maxInsertedItem + 1, Int.max)
                        }
                        
                        mappedTransition = (ChatHistoryListViewTransition(historyView: transition.historyView, deleteItems: deleteItems, insertItems: insertItems, updateItems: transition.updateItems, options: options, scrollToItem: scrollToItem, stationaryItemRange: stationaryItemRange), updateSizeAndInsets)
                    })
                    
                    if let mappedTransition = mappedTransition {
                        return mappedTransition
                    }
                }
                return (transition, nil)
            }
        }
        
        self.chatDisplayNode.requestUpdateChatInterfaceState = { [weak self] animated, f in
            self?.updateChatPresentationInterfaceState(animated: animated, { $0.updatedInterfaceState(f) })
        }
        
        self.chatDisplayNode.displayAttachmentMenu = { [weak self] in
            if let strongSelf = self {
                let controller = ChatMediaActionSheetController()
                controller.location = { [weak strongSelf] in
                    if let strongSelf = strongSelf {
                        let mapInputController = MapInputController()
                        strongSelf.present(mapInputController, in: .window)
                    }
                }
                controller.contacts = { [weak strongSelf] in
                    if let strongSelf = strongSelf {
                    }
                }
                strongSelf.present(controller, in: .window)
            }
        }
        
        self.chatDisplayNode.navigateToLatestButton.tapped = { [weak self] in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                strongSelf.chatDisplayNode.historyNode.scrollToEndOfHistory()
            }
        }
        
        let interfaceInteraction = ChatPanelInterfaceInteraction(setupReplyMessage: { [weak self] messageId in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, { $0.updatedInterfaceState { $0.withUpdatedReplyMessageId(message.id) } })
                    strongSelf.chatDisplayNode.ensureInputViewFocused()
                }
            }
        }, beginMessageSelection: { [weak self] messageId in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                    strongSelf.updateChatPresentationInterfaceState(animated: true, { $0.updatedInterfaceState { $0.withUpdatedSelectedMessage(message.id) } })
                }
            }
        }, deleteSelectedMessages: { [weak self] in
            if let strongSelf = self {
                if let messageIds = strongSelf.presentationInterfaceState.interfaceState.selectionState?.selectedIds, !messageIds.isEmpty {
                    strongSelf.account.postbox.modify({ modifier in
                        modifier.deleteMessages(Array(messageIds))
                    }).start()
                }
                strongSelf.updateChatPresentationInterfaceState(animated: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
            }
        }, forwardSelectedMessages: { [weak self] in
            if let strongSelf = self {
                let controller = ShareRecipientsActionSheetController()
                strongSelf.present(controller, in: .window)
            }
        }, updateTextInputState: { [weak self] textInputState in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState { $0.updatedInterfaceState { $0.withUpdatedInputState(textInputState) } }
            }
        })
        
        self.interfaceInteraction = interfaceInteraction
        self.chatDisplayNode.interfaceInteraction = interfaceInteraction
        
        self.displayNodeDidLoad()
    }
    
    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.chatDisplayNode.historyNode.preloadPages = true
        self.chatDisplayNode.historyNode.canReadHistory.set(.single(true))
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.containerLayout = layout
        
        self.chatDisplayNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationBar.frame.maxY, transition: transition,  listViewTransaction: { updateSizeAndInsets in
            self.chatDisplayNode.historyNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        })
    }
    
    func updateChatPresentationInterfaceState(animated: Bool = true, _ f: (ChatPresentationInterfaceState) -> ChatPresentationInterfaceState) {
        let temporaryChatPresentationInterfaceState = f(self.presentationInterfaceState)
        let inputContext = inputContextForChatPresentationIntefaceState(temporaryChatPresentationInterfaceState, account: self.account)
        let updatedChatPresentationInterfaceState = temporaryChatPresentationInterfaceState.updatedInputContext { _ in return inputContext }
        
        if self.isNodeLoaded {
            self.chatDisplayNode.updateChatPresentationInterfaceState(updatedChatPresentationInterfaceState, animated: animated)
        }
        self.presentationInterfaceState = updatedChatPresentationInterfaceState
        self.chatInterfaceStatePromise.set(.single(updatedChatPresentationInterfaceState.interfaceState))
        
        if let button = leftNavigationButtonForChatInterfaceState(updatedChatPresentationInterfaceState.interfaceState, currentButton: self.leftNavigationButton, target: self, selector: #selector(self.leftNavigationButtonAction)) {
            self.navigationItem.setLeftBarButton(button.buttonItem, animated: true)
            self.leftNavigationButton = button
        } else if let _ = self.leftNavigationButton {
            self.navigationItem.setLeftBarButton(nil, animated: true)
            self.leftNavigationButton = nil
        }
        
        if let button = rightNavigationButtonForChatInterfaceState(updatedChatPresentationInterfaceState.interfaceState, currentButton: self.rightNavigationButton, target: self, selector: #selector(self.rightNavigationButtonAction), chatInfoNavigationButton: self.chatInfoNavigationButton) {
            self.navigationItem.setRightBarButton(button.buttonItem, animated: true)
            self.rightNavigationButton = button
        } else if let _ = self.rightNavigationButton {
            self.navigationItem.setRightBarButton(nil, animated: true)
            self.rightNavigationButton = nil
        }
        
        if let controllerInteraction = self.controllerInteraction {
            if updatedChatPresentationInterfaceState.interfaceState.selectionState != controllerInteraction.selectionState {
                let animated = controllerInteraction.selectionState == nil || updatedChatPresentationInterfaceState.interfaceState.selectionState == nil
                controllerInteraction.selectionState = updatedChatPresentationInterfaceState.interfaceState.selectionState
                self.chatDisplayNode.historyNode.forEachItemNode { itemNode in
                    if let itemNode = itemNode as? ChatMessageItemView {
                        itemNode.updateSelectionState(animated: animated)
                    }
                }
            }
        }
    }
    
    @objc func leftNavigationButtonAction() {
        if let button = self.leftNavigationButton {
            self.navigationButtonAction(button.action)
        }
    }
    
    @objc func rightNavigationButtonAction() {
        if let button = self.rightNavigationButton {
            self.navigationButtonAction(button.action)
        }
    }
    
    private func navigationButtonAction(_ action: ChatNavigationButtonAction) {
        switch action {
            case .cancelMessageSelection:
                self.updateChatPresentationInterfaceState(animated: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
            case .clearHistory:
                let actionSheet = ActionSheetController()
                actionSheet.setItemGroups([ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: "Delete All Messages", color: .destructive, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ]), ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: "Cancel", color: .accent, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])])
                self.present(actionSheet, in: .window)
            case .openChatInfo:
                self.navigationActionDisposable.set((self.peerView.get()
                    |> take(1)
                    |> deliverOnMainQueue).start(next: { [weak self] peerView in
                        if let strongSelf = self, let _ = peerView.peers[peerView.peerId] {
                            let chatInfoController = PeerInfoController(account: strongSelf.account, peerId: peerView.peerId)
                            (strongSelf.navigationController as? NavigationController)?.pushViewController(chatInfoController)
                        }
                }))
                break
        }
    }
}
