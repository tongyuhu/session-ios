//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "ConversationViewCell.h"

@class OWSMessageBubbleView;
@protocol LKFriendRequestViewDelegate;

NS_ASSUME_NONNULL_BEGIN

@interface OWSMessageCell : ConversationViewCell

@property (nonatomic, readonly) OWSMessageBubbleView *messageBubbleView;
@property (nonatomic, nullable, weak) id<LKFriendRequestViewDelegate> friendRequestViewDelegate;

+ (NSString *)cellReuseIdentifier;

@end

NS_ASSUME_NONNULL_END
