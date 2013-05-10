//
//  BOMTalkTimelineEvent.h
//  BOMTalk
//
//  Created by Oliver Michalak on 30.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "BOMTalk.h"

@interface BOMTalkDebugEvent : NSObject

@property (strong, nonatomic) BOMTalkPeer *sourcePeer;
@property (strong, nonatomic) BOMTalkPeer *destPeer;
@property (strong, nonatomic) NSString *message;
@property (strong, nonatomic) NSDate *timestamp;

+ (id) eventFromPeer:(BOMTalkPeer*) sourcePeer toPeer:(BOMTalkPeer*) destPeer message: (NSString*) formatString, ...;

- (id) initWithEventFromPeer:(BOMTalkPeer*) sourcePeer toPeer:(BOMTalkPeer*) destPeer message: (NSString*) message;

@end
