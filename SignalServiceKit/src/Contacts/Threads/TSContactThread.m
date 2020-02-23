//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSContactThread.h"
#import "ContactsManagerProtocol.h"
#import "ContactsUpdater.h"
#import "NotificationsProtocol.h"
#import "OWSIdentityManager.h"
#import "SSKEnvironment.h"
#import <SignalServiceKit/SignalServiceKit-Swift.h>
#import <YapDatabase/YapDatabaseConnection.h>
#import <YapDatabase/YapDatabaseTransaction.h>
#import <SignalMetadataKit/SignalMetadataKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const TSContactThreadPrefix = @"c";

@implementation TSContactThread

- (instancetype)initWithContactId:(NSString *)contactId {
    NSString *uniqueIdentifier = [[self class] threadIdFromContactId:contactId];

    OWSAssertDebug(contactId.length > 0);

    self = [super initWithUniqueId:uniqueIdentifier];
    
    // No session reset ongoing
    _sessionResetStatus = LKSessionResetStatusNone;
    _sessionRestoreDevices = @[];

    return self;
}

+ (instancetype)getOrCreateThreadWithContactId:(NSString *)contactId
                                   transaction:(YapDatabaseReadWriteTransaction *)transaction {
    OWSAssertDebug(contactId.length > 0);

    TSContactThread *thread =
        [self fetchObjectWithUniqueID:[self threadIdFromContactId:contactId] transaction:transaction];

    if (!thread) {
        thread = [[TSContactThread alloc] initWithContactId:contactId];
        [thread saveWithTransaction:transaction];
    }

    return thread;
}

+ (instancetype)getOrCreateThreadWithContactId:(NSString *)contactId
{
    OWSAssertDebug(contactId.length > 0);

    __block TSContactThread *thread;
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        thread = [self getOrCreateThreadWithContactId:contactId transaction:transaction];
    }];

    return thread;
}

+ (nullable instancetype)getThreadWithContactId:(NSString *)contactId transaction:(YapDatabaseReadTransaction *)transaction;
{
    return [TSContactThread fetchObjectWithUniqueID:[self threadIdFromContactId:contactId] transaction:transaction];
}

- (NSString *)contactIdentifier {
    return [[self class] contactIdFromThreadId:self.uniqueId];
}

- (NSArray<NSString *> *)recipientIdentifiers
{
    return @[self.contactIdentifier];
}

- (BOOL)isGroupThread {
    return false;
}

- (BOOL)hasSafetyNumbers
{
    return !![[OWSIdentityManager sharedManager] identityKeyForRecipientId:self.contactIdentifier];
}

// TODO deprecate this? seems weird to access the displayName in the DB model
- (NSString *)name
{
    return [SSKEnvironment.shared.contactsManager displayNameForPhoneIdentifier:self.contactIdentifier];
}

+ (NSString *)threadIdFromContactId:(NSString *)contactId {
    return [TSContactThreadPrefix stringByAppendingString:contactId];
}

+ (NSString *)contactIdFromThreadId:(NSString *)threadId {
    return [threadId substringWithRange:NSMakeRange(1, threadId.length - 1)];
}

+ (NSString *)conversationColorNameForRecipientId:(NSString *)recipientId
                                      transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertDebug(recipientId.length > 0);

    TSContactThread *_Nullable contactThread =
        [TSContactThread getThreadWithContactId:recipientId transaction:transaction];
    if (contactThread) {
        return contactThread.conversationColorName;
    }
    return [self stableColorNameForNewConversationWithString:recipientId];
}

#pragma mark - Loki Session Restore

- (void)addSessionRestoreDevice:(NSString *)hexEncodedPublicKey transaction:(YapDatabaseReadWriteTransaction *_Nullable)transaction
{
    NSMutableSet *set = [[NSMutableSet alloc] initWithArray:_sessionRestoreDevices];
    [set addObject:hexEncodedPublicKey];
    [self setSessionRestoreDevices:set.allObjects transaction:transaction];
}

- (void)removeAllSessionRestoreDevicesWithTransaction:(YapDatabaseReadWriteTransaction *_Nullable)transaction
{
    [self setSessionRestoreDevices:@[] transaction:transaction];
}

- (void)setSessionRestoreDevices:(NSArray<NSString *> *)sessionRestoreDevices transaction:(YapDatabaseReadWriteTransaction *_Nullable)transaction {
    _sessionRestoreDevices = sessionRestoreDevices;
     void (^postNotification)() = ^() {
         [NSNotificationCenter.defaultCenter postNotificationName:NSNotification.threadSessionRestoreDevicesChanged object:self.uniqueId];
    };
    if (transaction == nil) {
        [self save];
        [self.dbReadWriteConnection flushTransactionsWithCompletionQueue:dispatch_get_main_queue() completionBlock:^{ postNotification(); }];
    } else {
        [self saveWithTransaction:transaction];
        [transaction.connection flushTransactionsWithCompletionQueue:dispatch_get_main_queue() completionBlock:^{ postNotification(); }];
    }
}

@end

NS_ASSUME_NONNULL_END
