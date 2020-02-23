//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "TSThread.h"
#import "NSString+SSK.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "OWSPrimaryStorage.h"
#import "OWSReadTracking.h"
#import "SSKEnvironment.h"
#import "TSAccountManager.h"
#import "TSDatabaseView.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSInteraction.h"
#import "TSInvalidIdentityKeyReceivingErrorMessage.h"
#import "TSOutgoingMessage.h"
#import <SignalCoreKit/Cryptography.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <YapDatabase/YapDatabase.h>

NS_ASSUME_NONNULL_BEGIN

BOOL IsNoteToSelfEnabled(void)
{
    return YES;
}

ConversationColorName const ConversationColorNameCrimson = @"red";
ConversationColorName const ConversationColorNameVermilion = @"orange";
ConversationColorName const ConversationColorNameBurlap = @"brown";
ConversationColorName const ConversationColorNameForest = @"green";
ConversationColorName const ConversationColorNameWintergreen = @"light_green";
ConversationColorName const ConversationColorNameTeal = @"teal";
ConversationColorName const ConversationColorNameBlue = @"blue";
ConversationColorName const ConversationColorNameIndigo = @"indigo";
ConversationColorName const ConversationColorNameViolet = @"purple";
ConversationColorName const ConversationColorNamePlum = @"pink";
ConversationColorName const ConversationColorNameTaupe = @"blue_grey";
ConversationColorName const ConversationColorNameSteel = @"grey";

ConversationColorName const kConversationColorName_Default = ConversationColorNameSteel;

@interface TSThread ()

@property (nonatomic) NSDate *creationDate;
@property (nonatomic) NSString *conversationColorName;
@property (nonatomic, nullable) NSNumber *archivedAsOfMessageSortId;
@property (nonatomic, copy, nullable) NSString *messageDraft;
@property (atomic, nullable) NSDate *mutedUntilDate;

// DEPRECATED - not used since migrating to sortId
// but keeping these properties around to ease any pain in the back-forth
// migration while testing. Eventually we can safely delete these as they aren't used anywhere.
@property (nonatomic, nullable) NSDate *lastMessageDate DEPRECATED_ATTRIBUTE;
@property (nonatomic, nullable) NSDate *archivalDate DEPRECATED_ATTRIBUTE;

@end

#pragma mark -

@implementation TSThread

#pragma mark - Dependencies

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

#pragma mark -

+ (NSString *)collection {
    return @"TSThread";
}

- (instancetype)initWithUniqueId:(NSString *_Nullable)uniqueId
{
    self = [super initWithUniqueId:uniqueId];

    if (self) {
        _creationDate    = [NSDate date];
        _messageDraft    = nil;

        NSString *_Nullable contactId = self.contactIdentifier;
        if (contactId.length > 0) {
            // To be consistent with colors synced to desktop
            _conversationColorName = [self.class stableColorNameForNewConversationWithString:contactId];
        } else {
            _conversationColorName = [self.class stableColorNameForNewConversationWithString:self.uniqueId];
        }
        
        // Loki: Friend request logic doesn't apply to group chats
        if (self.isGroupThread) {
            _friendRequestStatus = LKThreadFriendRequestStatusFriends;
        } else {
            _friendRequestStatus = LKThreadFriendRequestStatusNone;
        }
    }

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    // renamed `hasEverHadMessage` -> `shouldThreadBeVisible`
    if (!_shouldThreadBeVisible) {
        NSNumber *_Nullable legacy_hasEverHadMessage = [coder decodeObjectForKey:@"hasEverHadMessage"];

        if (legacy_hasEverHadMessage != nil) {
            _shouldThreadBeVisible = legacy_hasEverHadMessage.boolValue;
        }
    }

    if (_conversationColorName.length == 0) {
        NSString *_Nullable colorSeed = self.contactIdentifier;
        if (colorSeed.length > 0) {
            // group threads
            colorSeed = self.uniqueId;
        }

        // To be consistent with colors synced to desktop
        ConversationColorName colorName = [self.class stableColorNameForLegacyConversationWithString:colorSeed];
        OWSAssertDebug(colorName);

        _conversationColorName = colorName;
    } else if (![[[self class] conversationColorNames] containsObject:_conversationColorName]) {
        // If we'd persisted a non-mapped color name
        ConversationColorName _Nullable mappedColorName = self.class.legacyConversationColorMap[_conversationColorName];

        if (!mappedColorName) {
            // We previously used the wrong values for the new colors, it's possible we persited them.
            // map them to the proper value
            mappedColorName = self.class.legacyFixupConversationColorMap[_conversationColorName];
        }

        if (!mappedColorName) {
            OWSFailDebug(@"failure: unexpected unmappable conversationColorName: %@", _conversationColorName);
            mappedColorName = kConversationColorName_Default;
        }

        _conversationColorName = mappedColorName;
    }

    NSDate *_Nullable lastMessageDate = [coder decodeObjectOfClass:NSDate.class forKey:@"lastMessageDate"];
    NSDate *_Nullable archivalDate = [coder decodeObjectOfClass:NSDate.class forKey:@"archivalDate"];
    _isArchivedByLegacyTimestampForSorting =
        [self.class legacyIsArchivedWithLastMessageDate:lastMessageDate archivalDate:archivalDate];

    return self;
}

- (void)saveWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [super saveWithTransaction:transaction];
    
    [SSKPreferences setHasSavedThreadWithValue:YES transaction:transaction];
}

- (void)removeWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self removeAllThreadInteractionsWithTransaction:transaction];

    [super removeWithTransaction:transaction];
}

- (void)removeAllThreadInteractionsWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    // We can't safely delete interactions while enumerating them, so
    // we collect and delete separately.
    //
    // We don't want to instantiate the interactions when collecting them
    // or when deleting them.
    NSMutableArray<NSString *> *interactionIds = [NSMutableArray new];
    YapDatabaseViewTransaction *interactionsByThread = [transaction ext:TSMessageDatabaseViewExtensionName];
    OWSAssertDebug(interactionsByThread);
    __block BOOL didDetectCorruption = NO;
    [interactionsByThread enumerateKeysInGroup:self.uniqueId
                                    usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
                                        if (![key isKindOfClass:[NSString class]] || key.length < 1) {
                                            OWSFailDebug(
                                                @"invalid key in thread interactions: %@, %@.", key, [key class]);
                                            didDetectCorruption = YES;
                                            return;
                                        }
                                        [interactionIds addObject:key];
                                    }];

    if (didDetectCorruption) {
        OWSLogWarn(@"incrementing version of: %@", TSMessageDatabaseViewExtensionName);
        [OWSPrimaryStorage incrementVersionOfDatabaseExtension:TSMessageDatabaseViewExtensionName];
    }

    for (NSString *interactionId in interactionIds) {
        // We need to fetch each interaction, since [TSInteraction removeWithTransaction:] does important work.
        TSInteraction *_Nullable interaction =
            [TSInteraction fetchObjectWithUniqueID:interactionId transaction:transaction];
        if (!interaction) {
            OWSFailDebug(@"couldn't load thread's interaction for deletion.");
            continue;
        }
        [interaction removeWithTransaction:transaction];
    }
}

- (BOOL)isNoteToSelf
{
    if (!IsNoteToSelfEnabled()) {
        return NO;
    }
    NSString *localNumber = self.tsAccountManager.localNumber;
    NSString *masterDeviceHexEncodedPublicKey = [NSUserDefaults.standardUserDefaults stringForKey:@"masterDeviceHexEncodedPublicKey"];
    bool isOurNumber = [self.contactIdentifier isEqualToString:localNumber] || (masterDeviceHexEncodedPublicKey != nil && [self.contactIdentifier isEqualToString:masterDeviceHexEncodedPublicKey]);
    return (!self.isGroupThread && self.contactIdentifier != nil && isOurNumber);
}

#pragma mark - To be subclassed.

- (BOOL)isGroupThread {
    OWSAbstractMethod();

    return NO;
}

// Override in ContactThread
- (nullable NSString *)contactIdentifier
{
    return nil;
}

- (NSString *)name {
    OWSAbstractMethod();

    return nil;
}

- (NSArray<NSString *> *)recipientIdentifiers
{
    OWSAbstractMethod();

    return @[];
}

- (BOOL)hasSafetyNumbers
{
    return NO;
}

#pragma mark - Interactions

/**
 * Iterate over this thread's interactions
 */
- (void)enumerateInteractionsWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
                                  usingBlock:(void (^)(TSInteraction *interaction,
                                                 YapDatabaseReadTransaction *transaction))block
{
    YapDatabaseViewTransaction *interactionsByThread = [transaction ext:TSMessageDatabaseViewExtensionName];
    [interactionsByThread
        enumerateKeysAndObjectsInGroup:self.uniqueId
                            usingBlock:^(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop) {
                                TSInteraction *interaction = object;
                                block(interaction, transaction);
                            }];
}

/**
 * Enumerates all the threads interactions. Note this will explode if you try to create a transaction in the block.
 * If you need a transaction, use the sister method: `enumerateInteractionsWithTransaction:usingBlock`
 */
- (void)enumerateInteractionsUsingBlock:(void (^)(TSInteraction *interaction))block
{
    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self enumerateInteractionsWithTransaction:transaction
                                        usingBlock:^(
                                            TSInteraction *interaction, YapDatabaseReadTransaction *transaction) {

                                            block(interaction);
                                        }];
    }];
}

- (TSInteraction *)lastInteraction
{
    __block TSInteraction *interaction;
    [self.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        interaction = [self getLastInteractionWithTransaction:transaction];
    }];
    return interaction;
}

- (TSInteraction *)getLastInteractionWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    YapDatabaseViewTransaction *interactions = [transaction ext:TSMessageDatabaseViewExtensionName];
    return [interactions lastObjectInGroup:self.uniqueId];
}

/**
 * Useful for tests and debugging. In production use an enumeration method.
 */
- (NSArray<TSInteraction *> *)allInteractions
{
    NSMutableArray<TSInteraction *> *interactions = [NSMutableArray new];
    [self enumerateInteractionsUsingBlock:^(TSInteraction *interaction) {
        [interactions addObject:interaction];
    }];

    return [interactions copy];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (NSArray<TSInvalidIdentityKeyReceivingErrorMessage *> *)receivedMessagesForInvalidKey:(NSData *)key
{
    NSMutableArray *errorMessages = [NSMutableArray new];
    [self enumerateInteractionsUsingBlock:^(TSInteraction *interaction) {
        if ([interaction isKindOfClass:[TSInvalidIdentityKeyReceivingErrorMessage class]]) {
            TSInvalidIdentityKeyReceivingErrorMessage *error = (TSInvalidIdentityKeyReceivingErrorMessage *)interaction;
            @try {
                if ([[error throws_newIdentityKey] isEqualToData:key]) {
                    [errorMessages addObject:(TSInvalidIdentityKeyReceivingErrorMessage *)interaction];
                }
            } @catch (NSException *exception) {
                OWSFailDebug(@"exception: %@", exception);
            }
        }
    }];

    return [errorMessages copy];
}
#pragma clang diagnostic pop

- (NSUInteger)numberOfInteractions
{
    __block NSUInteger count;
    [[self dbReadConnection] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        YapDatabaseViewTransaction *interactionsByThread = [transaction ext:TSMessageDatabaseViewExtensionName];
        count = [interactionsByThread numberOfItemsInGroup:self.uniqueId];
    }];
    return count;
}

- (NSArray<id<OWSReadTracking>> *)unseenMessagesWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    NSMutableArray<id<OWSReadTracking>> *messages = [NSMutableArray new];
    [[TSDatabaseView unseenDatabaseViewExtension:transaction]
        enumerateKeysAndObjectsInGroup:self.uniqueId
                            usingBlock:^(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop) {
                                if (![object conformsToProtocol:@protocol(OWSReadTracking)]) {
                                    OWSFailDebug(@"Unexpected object in unseen messages: %@", [object class]);
                                    return;
                                }
                                [messages addObject:(id<OWSReadTracking>)object];
                            }];

    return [messages copy];
}

- (NSUInteger)unreadMessageCountWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [[transaction ext:TSUnreadDatabaseViewExtensionName] numberOfItemsInGroup:self.uniqueId];
}

- (void)markAllAsReadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    for (id<OWSReadTracking> message in [self unseenMessagesWithTransaction:transaction]) {
        [message markAsReadAtTimestamp:[NSDate ows_millisecondTimeStamp] sendReadReceipt:YES transaction:transaction];
    }

    // Just to be defensive, we'll also check for unread messages.
    OWSAssertDebug([self unseenMessagesWithTransaction:transaction].count < 1);
}

- (nullable TSInteraction *)lastInteractionForInboxWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(transaction);

    __block NSUInteger missedCount = 0;
    __block TSInteraction *last = nil;
    [[transaction ext:TSMessageDatabaseViewExtensionName]
        enumerateKeysAndObjectsInGroup:self.uniqueId
                           withOptions:NSEnumerationReverse
                            usingBlock:^(NSString *collection, NSString *key, id object, NSUInteger index, BOOL *stop) {
                                OWSAssertDebug([object isKindOfClass:[TSInteraction class]]);

                                missedCount++;
                                TSInteraction *interaction = (TSInteraction *)object;

                                if ([TSThread shouldInteractionAppearInInbox:interaction]) {
                                    last = interaction;

                                    // For long ignored threads, with lots of SN changes this can get really slow.
                                    // I see this in development because I have a lot of long forgotten threads with
                                    // members who's test devices are constantly reinstalled. We could add a
                                    // purpose-built DB view, but I think in the real world this is rare to be a
                                    // hotspot.
                                    if (missedCount > 50) {
                                        OWSLogWarn(@"found last interaction for inbox after skipping %lu items",
                                            (unsigned long)missedCount);
                                    }
                                    *stop = YES;
                                }
                            }];
    return last;
}

- (NSString *)lastMessageTextWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    TSInteraction *interaction = [self lastInteractionForInboxWithTransaction:transaction];
    if ([interaction conformsToProtocol:@protocol(OWSPreviewText)]) {
        id<OWSPreviewText> previewable = (id<OWSPreviewText>)interaction;
        return [previewable previewTextWithTransaction:transaction].filterStringForDisplay;
    } else {
        return @"";
    }
}

// Returns YES IFF the interaction should show up in the inbox as the last message.
+ (BOOL)shouldInteractionAppearInInbox:(TSInteraction *)interaction
{
    OWSAssertDebug(interaction);

    if (interaction.isDynamicInteraction) {
        return NO;
    }

    if ([interaction isKindOfClass:[TSErrorMessage class]]) {
        TSErrorMessage *errorMessage = (TSErrorMessage *)interaction;
        if (errorMessage.errorType == TSErrorMessageNonBlockingIdentityChange) {
            // Otherwise all group threads with the recipient will percolate to the top of the inbox, even though
            // there was no meaningful interaction.
            return NO;
        }
    } else if ([interaction isKindOfClass:[TSInfoMessage class]]) {
        TSInfoMessage *infoMessage = (TSInfoMessage *)interaction;
        if (infoMessage.messageType == TSInfoMessageVerificationStateChange) {
            return NO;
        }
    }

    return YES;
}

- (void)updateWithLastMessage:(TSInteraction *)lastMessage transaction:(YapDatabaseReadWriteTransaction *)transaction {
    OWSAssertDebug(lastMessage);
    OWSAssertDebug(transaction);

    if (![self.class shouldInteractionAppearInInbox:lastMessage]) {
        return;
    }

    if (!self.shouldThreadBeVisible) {
        self.shouldThreadBeVisible = YES;
        [self saveWithTransaction:transaction];
    } else {
        [self touchWithTransaction:transaction];
    }
}

#pragma mark - Disappearing Messages

- (OWSDisappearingMessagesConfiguration *)disappearingMessagesConfigurationWithTransaction:
    (YapDatabaseReadTransaction *)transaction
{
    return [OWSDisappearingMessagesConfiguration fetchOrBuildDefaultWithThreadId:self.uniqueId transaction:transaction];
}

- (uint32_t)disappearingMessagesDurationWithTransaction:(YapDatabaseReadTransaction *)transaction
{

    OWSDisappearingMessagesConfiguration *config = [self disappearingMessagesConfigurationWithTransaction:transaction];

    if (!config.isEnabled) {
        return 0;
    } else {
        return config.durationSeconds;
    }
}

#pragma mark - Archival

- (BOOL)isArchivedWithTransaction:(YapDatabaseReadTransaction *)transaction;
{
    if (!self.archivedAsOfMessageSortId) {
        return NO;
    }

    TSInteraction *_Nullable latestInteraction = [self lastInteractionForInboxWithTransaction:transaction];
    uint64_t latestSortIdForInbox = latestInteraction ? latestInteraction.sortId : 0;
    return self.archivedAsOfMessageSortId.unsignedLongLongValue >= latestSortIdForInbox;
}

+ (BOOL)legacyIsArchivedWithLastMessageDate:(nullable NSDate *)lastMessageDate
                               archivalDate:(nullable NSDate *)archivalDate
{
    if (!archivalDate) {
        return NO;
    }

    if (!lastMessageDate) {
        return YES;
    }

    return [archivalDate compare:lastMessageDate] != NSOrderedAscending;
}

- (void)archiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSThread *thread) {
                                 uint64_t latestId = [SSKIncrementingIdFinder previousIdWithKey:TSInteraction.collection
                                                                                    transaction:transaction];
                                 thread.archivedAsOfMessageSortId = @(latestId);
                             }];

    [self markAllAsReadWithTransaction:transaction];
}

- (void)unarchiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSThread *thread) {
                                 thread.archivedAsOfMessageSortId = nil;
                             }];
}

#pragma mark - Drafts

- (NSString *)currentDraftWithTransaction:(YapDatabaseReadTransaction *)transaction {
    TSThread *thread = [TSThread fetchObjectWithUniqueID:self.uniqueId transaction:transaction];
    if (thread.messageDraft) {
        return thread.messageDraft;
    } else {
        return @"";
    }
}

- (void)setDraft:(NSString *)draftString transaction:(YapDatabaseReadWriteTransaction *)transaction {
    TSThread *thread    = [TSThread fetchObjectWithUniqueID:self.uniqueId transaction:transaction];
    thread.messageDraft = draftString;
    [thread saveWithTransaction:transaction];
}

#pragma mark - Muted

- (BOOL)isMuted
{
    NSDate *mutedUntilDate = self.mutedUntilDate;
    NSDate *now = [NSDate date];
    return (mutedUntilDate != nil &&
            [mutedUntilDate timeIntervalSinceDate:now] > 0);
}

- (void)updateWithMutedUntilDate:(NSDate *)mutedUntilDate transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSThread *thread) {
                                 [thread setMutedUntilDate:mutedUntilDate];
                             }];
}

#pragma mark - Conversation Color

- (ConversationColorName)conversationColorName
{
    OWSAssertDebug([self.class.conversationColorNames containsObject:_conversationColorName]);
    return _conversationColorName;
}

+ (NSArray<ConversationColorName> *)colorNamesForNewConversation
{
    // all conversation colors except "steel"
    return @[
        ConversationColorNameCrimson,
        ConversationColorNameVermilion,
        ConversationColorNameBurlap,
        ConversationColorNameForest,
        ConversationColorNameWintergreen,
        ConversationColorNameTeal,
        ConversationColorNameBlue,
        ConversationColorNameIndigo,
        ConversationColorNameViolet,
        ConversationColorNamePlum,
        ConversationColorNameTaupe,
    ];
}

+ (NSArray<ConversationColorName> *)conversationColorNames
{
    return [self.colorNamesForNewConversation arrayByAddingObject:kConversationColorName_Default];
}

+ (ConversationColorName)stableConversationColorNameForString:(NSString *)colorSeed
                                                   colorNames:(NSArray<ConversationColorName> *)colorNames
{
    NSData *contactData = [colorSeed dataUsingEncoding:NSUTF8StringEncoding];

    unsigned long long hash = 0;
    NSUInteger hashingLength = sizeof(hash);
    NSData *_Nullable hashData = [Cryptography computeSHA256Digest:contactData truncatedToBytes:hashingLength];
    if (hashData) {
        [hashData getBytes:&hash length:hashingLength];
    } else {
        OWSFailDebug(@"could not compute hash for color seed.");
    }

    NSUInteger index = (hash % colorNames.count);
    return [colorNames objectAtIndex:index];
}

+ (ConversationColorName)stableColorNameForNewConversationWithString:(NSString *)colorSeed
{
    return [self stableConversationColorNameForString:colorSeed colorNames:self.colorNamesForNewConversation];
}

// After introducing new conversation colors, we want to try to maintain as close as possible to the old color for an
// existing thread.
+ (ConversationColorName)stableColorNameForLegacyConversationWithString:(NSString *)colorSeed
{
    NSString *legacyColorName =
        [self stableConversationColorNameForString:colorSeed colorNames:self.legacyConversationColorNames];
    ConversationColorName _Nullable mappedColorName = self.class.legacyConversationColorMap[legacyColorName];

    if (!mappedColorName) {
        OWSFailDebug(@"failure: unexpected unmappable legacyColorName: %@", legacyColorName);
        return kConversationColorName_Default;
    }

    return mappedColorName;
}

+ (NSArray<NSString *> *)legacyConversationColorNames
{
    return @[
             @"red",
             @"pink",
             @"purple",
             @"indigo",
             @"blue",
             @"cyan",
             @"teal",
             @"green",
             @"deep_orange",
             @"grey"
    ];
}

+ (NSDictionary<NSString *, ConversationColorName> *)legacyConversationColorMap
{
    static NSDictionary<NSString *, ConversationColorName> *colorMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorMap = @{
            @"red" : ConversationColorNameCrimson,
            @"deep_orange" : ConversationColorNameCrimson,
            @"orange" : ConversationColorNameVermilion,
            @"amber" : ConversationColorNameVermilion,
            @"brown" : ConversationColorNameBurlap,
            @"yellow" : ConversationColorNameBurlap,
            @"pink" : ConversationColorNamePlum,
            @"purple" : ConversationColorNameViolet,
            @"deep_purple" : ConversationColorNameViolet,
            @"indigo" : ConversationColorNameIndigo,
            @"blue" : ConversationColorNameBlue,
            @"light_blue" : ConversationColorNameBlue,
            @"cyan" : ConversationColorNameTeal,
            @"teal" : ConversationColorNameTeal,
            @"green" : ConversationColorNameForest,
            @"light_green" : ConversationColorNameWintergreen,
            @"lime" : ConversationColorNameWintergreen,
            @"blue_grey" : ConversationColorNameTaupe,
            @"grey" : ConversationColorNameSteel,
        };
    });

    return colorMap;
}

// we temporarily used the wrong value for the new color names.
+ (NSDictionary<NSString *, ConversationColorName> *)legacyFixupConversationColorMap
{
    static NSDictionary<NSString *, ConversationColorName> *colorMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorMap = @{
            @"crimson" : ConversationColorNameCrimson,
            @"vermilion" : ConversationColorNameVermilion,
            @"burlap" : ConversationColorNameBurlap,
            @"forest" : ConversationColorNameForest,
            @"wintergreen" : ConversationColorNameWintergreen,
            @"teal" : ConversationColorNameTeal,
            @"blue" : ConversationColorNameBlue,
            @"indigo" : ConversationColorNameIndigo,
            @"violet" : ConversationColorNameViolet,
            @"plum" : ConversationColorNamePlum,
            @"taupe" : ConversationColorNameTaupe,
            @"steel" : ConversationColorNameSteel,
        };
    });

    return colorMap;
}

- (void)updateConversationColorName:(ConversationColorName)colorName
                        transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSThread *thread) {
                                 thread.conversationColorName = colorName;
                             }];
}

#pragma mark - Loki Friend Request Handling

- (void)removeOldOutgoingFriendRequestMessagesIfNeededWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self removeOldFriendRequestMessagesIfNeeded:OWSInteractionType_OutgoingMessage withTransaction:transaction];
}

- (void)removeOldIncomingFriendRequestMessagesIfNeededWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self removeOldFriendRequestMessagesIfNeeded:OWSInteractionType_IncomingMessage withTransaction:transaction];
}

- (void)removeOldFriendRequestMessagesIfNeeded:(OWSInteractionType)interactionType withTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    // If we're friends with the person then we don't need to remove any friend request messages
    if (self.friendRequestStatus == LKThreadFriendRequestStatusFriends) { return; }
    
    NSMutableArray<NSString *> *idsToRemove = [NSMutableArray new];
    __block TSMessage *_Nullable messageToKeep = nil; // We want to keep this interaction and not remove it

    [self enumerateInteractionsWithTransaction:transaction usingBlock:^(TSInteraction *interaction, YapDatabaseReadTransaction *transaction) {
        if (interaction.interactionType != interactionType) { return; }
        
        BOOL removeMessage = false;
        TSMessage *message = (TSMessage *)interaction;
        
        // We want to keep the most recent message
        if (messageToKeep == nil || messageToKeep.timestamp < message.timestamp) {
            messageToKeep = message;
        }
        
        // We want to remove any old incoming friend request messages which are pending
        if (interactionType == OWSInteractionType_IncomingMessage) {
            removeMessage = YES;
        } else {
            // Or if we're sending then remove any failed friend request messages
            TSOutgoingMessage *outgoingMessage = (TSOutgoingMessage *)message;
            removeMessage = outgoingMessage.friendRequestStatus == LKMessageFriendRequestStatusSendingOrFailed;
        }
        
        if (removeMessage) {
            [idsToRemove addObject:interaction.uniqueId];
        }
    }];
    
    for (NSString *interactionId in idsToRemove) {
        // Don't delete the recent message
        if (messageToKeep != nil && interactionId == messageToKeep.uniqueId) { continue; }
        
        // We need to fetch each interaction, since [TSInteraction removeWithTransaction:] does important work
        TSInteraction *_Nullable interaction = [TSInteraction fetchObjectWithUniqueID:interactionId transaction:transaction];
        if (!interaction) {
            OWSFailDebug(@"couldn't load thread's interaction for deletion.");
            continue;
        }
        [interaction removeWithTransaction:transaction];
    }
}

- (void)saveFriendRequestStatus:(LKThreadFriendRequestStatus)friendRequestStatus withTransaction:(YapDatabaseReadWriteTransaction *_Nullable)transaction
{
    self.friendRequestStatus = friendRequestStatus;
    NSLog(@"[Loki] Setting thread friend request status to %@.", self.friendRequestStatusDescription);
    void (^postNotification)() = ^() {
        [NSNotificationCenter.defaultCenter postNotificationName:NSNotification.threadFriendRequestStatusChanged object:self.uniqueId];
    };
    if (transaction == nil) {
        [self save];
        [self.dbReadWriteConnection flushTransactionsWithCompletionQueue:dispatch_get_main_queue() completionBlock:^{ postNotification(); }];
    } else {
        [self saveWithTransaction:transaction];
        [transaction.connection flushTransactionsWithCompletionQueue:dispatch_get_main_queue() completionBlock:^{ postNotification(); }];
    }
}

- (NSString *)friendRequestStatusDescription
{
    switch (self.friendRequestStatus) {
        case LKThreadFriendRequestStatusNone: return @"none";
        case LKThreadFriendRequestStatusRequestSending: return @"sending";
        case LKThreadFriendRequestStatusRequestSent: return @"sent";
        case LKThreadFriendRequestStatusRequestReceived: return @"received";
        case LKThreadFriendRequestStatusFriends: return @"friends";
        case LKThreadFriendRequestStatusRequestExpired: return @"expired";
    }
}

- (BOOL)hasPendingFriendRequest
{
    return self.friendRequestStatus == LKThreadFriendRequestStatusRequestSending || self.friendRequestStatus == LKThreadFriendRequestStatusRequestSent
        || self.friendRequestStatus == LKThreadFriendRequestStatusRequestReceived;
}

- (BOOL)isContactFriend
{
    return self.friendRequestStatus == LKThreadFriendRequestStatusFriends;
}

- (BOOL)hasCurrentUserSentFriendRequest
{
    return self.friendRequestStatus == LKThreadFriendRequestStatusRequestSent;
}

- (BOOL)hasCurrentUserReceivedFriendRequest
{
    return self.friendRequestStatus == LKThreadFriendRequestStatusRequestReceived;
}

@end

NS_ASSUME_NONNULL_END
