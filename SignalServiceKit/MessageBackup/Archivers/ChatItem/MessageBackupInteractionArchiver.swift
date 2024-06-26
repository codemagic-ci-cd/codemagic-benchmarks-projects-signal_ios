//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension MessageBackup {

    public struct ChatItemId: ExpressibleByIntegerLiteral, Hashable {

        public typealias IntegerLiteralType = UInt64

        internal let value: UInt64

        public init(integerLiteral value: UInt64) {
            self.value = value
        }

        fileprivate init(_ value: UInt64) {
            self.value = value
        }

        public init(interaction: TSInteraction) {
            self.value = interaction.timestamp
        }
    }

    internal enum ChatItemMessageType {
        case standard(BackupProtoStandardMessage)
        case contact(BackupProtoContactMessage)
        case voice(BackupProtoVoiceMessage)
        case sticker(BackupProtoStickerMessage)
        case remotelyDeleted(BackupProtoRemoteDeletedMessage)
        case chatUpdate(BackupProtoChatUpdateMessage)

        init?(_ chatItem: BackupProtoChatItem) {
            if let standardMessage = chatItem.standardMessage {
                self = .standard(standardMessage)
            } else if let contactMessage = chatItem.contactMessage {
                self = .contact(contactMessage)
            } else if let voiceMessage = chatItem.voiceMessage {
                self = .voice(voiceMessage)
            } else if let stickerMessage = chatItem.stickerMessage {
                self = .sticker(stickerMessage)
            } else if let remoteDeletedMessage = chatItem.remoteDeletedMessage {
                self = .remotelyDeleted(remoteDeletedMessage)
            } else if let updateMessage = chatItem.updateMessage {
                self = .chatUpdate(updateMessage)
            } else {
                owsFailDebug("Unknown chat item type!")
                return nil
            }
        }
    }

    internal struct InteractionArchiveDetails {
        enum DirectionalDetails {
            case incoming(BackupProtoChatItemIncomingMessageDetails)
            case outgoing(BackupProtoChatItemOutgoingMessageDetails)
            // TODO: do we need to modify the proto schema for local
            // messages that are neither incoming nor outgoing?
            // Or do we just call them outgoing, with no recipients?
        }

        let author: RecipientId
        let directionalDetails: DirectionalDetails
        let expireStartDate: UInt64?
        let expiresInMs: UInt64?
        // TODO: edit revisions
        let revisions: [BackupProtoChatItem] = []
        // TODO: sms
        let isSms: Bool = false
        let isSealedSender: Bool
        let type: ChatItemMessageType
    }

    internal enum ArchiveInteractionResult<Component> {
        typealias Error = MessageBackupChatItemArchiver.ArchiveMultiFrameResult.Error

        case success(Component)

        // MARK: Skips

        /// This is a past revision that was since edited; can be safely skipped, as its
        /// contents will be represented in the latest revision.
        case isPastRevision
        // TODO: remove this once we flesh out implementation for all interactions.
        case notYetImplemented

        // MARK: Errors

        /// Some portion of the interaction failed to archive, but we can still archive the rest of it.
        /// e.g. some recipient details are missing, so we archive without that recipient.
        case partialFailure(Component, [Error])
        /// The entire message failed and should be skipped.
        /// Other messages are unaffected.
        case messageFailure([Error])
        /// Catastrophic failure, which should stop _all_ message archiving.
        case completeFailure(Swift.Error)
    }

    internal enum RestoreInteractionResult<Component> {
        case success(Component)
        /// Some portion of the interaction failed to restore, but we can still restore the rest of it.
        /// e.g. a reaction failed to parse, so we just drop that reaction.
        case partialRestore(Component, [RestoringFrameError])
        /// The entire message failed and should be skipped.
        /// Other messages are unaffected.
        case messageFailure([RestoringFrameError])
    }
}

internal protocol MessageBackupInteractionArchiver: MessageBackupProtoArchiver {

    typealias Details = MessageBackup.InteractionArchiveDetails

    static func canArchiveInteraction(_ interaction: TSInteraction) -> Bool

    func archiveInteraction(
        _ interaction: TSInteraction,
        context: MessageBackup.ChatArchivingContext,
        tx: DBReadTransaction
    ) -> MessageBackup.ArchiveInteractionResult<Details>

    static func canRestoreChatItem(_ chatItem: BackupProtoChatItem) -> Bool

    func restoreChatItem(
        _ chatItem: BackupProtoChatItem,
        thread: MessageBackup.ChatThread,
        context: MessageBackup.ChatRestoringContext,
        tx: DBWriteTransaction
    ) -> MessageBackup.RestoreInteractionResult<Void>
}

extension MessageBackup.ArchiveInteractionResult {

    enum BubbleUp<T, E> {
        case `continue`(T)
        case bubbleUpError(MessageBackup.ArchiveInteractionResult<E>)
    }

    /// Make it easier to "bubble up" an error case of ``ArchiveInteractionResult`` thrown deeper in the call stack.
    /// Basically, collapses all the cases that should just be bubbled up to the caller (error cases) into an easily returnable case,
    /// ditto for the success or partial success cases, and handles updating partialErrors along the way.
    ///
    /// Concretely, turns this:
    ///
    /// switch someResult {
    /// case .success(let value):
    ///   myVar = value
    /// case .partialFailure(let value, let errors):
    ///   myVar = value
    ///   partialErrors.append(contentsOf: errors)
    /// case someFailureCase(let someErrorOrErrors)
    ///   let coalescedErrorOrErrors = partialErrors.coalesceSomehow(with: someErrorOrErrors)
    ///   // Just bubble up the error after coalescing
    ///   return .someFailureCase(coalescedErrorOrErrors)
    /// // ...
    /// // The same for every other error case that should be bubbled up
    /// // ...
    /// }
    ///
    /// Into this:
    ///
    /// switch someResult.bubbleUp(&partialErrors) {
    /// case .success(let value):
    ///   myVar = value
    /// case .bubbleUpError(let error):
    ///   return error
    /// }
    func bubbleUp<ErrorResultType>(
        _ resultType: ErrorResultType.Type = ErrorResultType.self,
        partialErrors: inout [Error]
    ) -> BubbleUp<Component, ErrorResultType> {
        switch self {
        case .success(let value):
            return .continue(value)

        case .partialFailure(let value, let errors):
            // Continue through partial failures.
            partialErrors.append(contentsOf: errors)
            return .continue(value)

        // These types are just bubbled up as-is
        case .isPastRevision:
            return .bubbleUpError(.isPastRevision)
        case .notYetImplemented:
            return .bubbleUpError(.notYetImplemented)
        case .completeFailure(let error):
            return .bubbleUpError(.completeFailure(error))

        case .messageFailure(let errors):
            // Add message failure to partial errors and bubble it up.
            partialErrors.append(contentsOf: errors)
            return .bubbleUpError(.messageFailure(partialErrors))
        }
    }
}

extension MessageBackup.RestoreInteractionResult {

    /// Returns nil for ``RestoreInteractionResult.messageFailure``, otherwise
    /// returns the restored component. Regardless, accumulates any errors so that the caller
    /// can return the passed in ``partialErrors`` array in the final result.
    ///
    /// Concretely, turns this:
    ///
    /// switch someResult {
    /// case .success(let value):
    ///   myVar = value
    /// case .partialRestore(let value, let errors):
    ///   myVar = value
    ///   partialErrors.append(contentsOf: errors)
    /// case messageFailure(let errors)
    ///   partialErrors.append(contentsOf: errors)
    ///   return .messageFailure(partialErrors)
    /// }
    ///
    /// Into this:
    ///
    /// guard let myVar = someResult.unwrap(&partialErrors) else {
    ///   return .messageFailure(partialErrors)
    /// }
    func unwrap(partialErrors: inout [MessageBackup.RestoringFrameError]) -> Component? {
        switch self {
        case .success(let component):
            return component
        case .partialRestore(let component, let errors):
            partialErrors.append(contentsOf: errors)
            return component
        case .messageFailure(let errors):
            partialErrors.append(contentsOf: errors)
            return nil
        }
    }
}

extension MessageBackup.RestoreInteractionResult where Component == Void {

    /// Returns false for ``RestoreInteractionResult.messageFailure``, otherwise
    /// returns true. Regardless, accumulates any errors so that the caller
    /// can return the passed in ``partialErrors`` array in the final result.
    func unwrap(partialErrors: inout [MessageBackup.RestoringFrameError]) -> Bool {
        switch self {
        case .success:
            return true
        case .partialRestore(_, let errors):
            partialErrors.append(contentsOf: errors)
            return true
        case .messageFailure(let errors):
            partialErrors.append(contentsOf: errors)
            return false
        }
    }
}

extension BackupProtoChatItem {

    var id: MessageBackup.ChatItemId {
        return .init(self.dateSent)
    }

    var messageType: MessageBackup.ChatItemMessageType? {
        return .init(self)
    }
}

extension TSInteraction {

    var chatItemId: MessageBackup.ChatItemId {
        return .init(interaction: self)
    }
}
