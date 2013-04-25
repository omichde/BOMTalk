//
//  SessionPeerClass.h
//  werk01.de
//

#import <Foundation/Foundation.h>

typedef enum {
	BOMTalkPeerStateIdle = 1,
	BOMTalkPeerStateVisible,
	BOMTalkPeerStateConnecting,
	BOMTalkPeerStateConnected
} BOMTalkPeerState;

@interface BOMTalkPeer : NSObject

@property (strong, nonatomic) NSString *peerID;
@property (strong, nonatomic) NSString *name;
@property (assign, nonatomic) BOMTalkPeerState state;
@property (strong, nonatomic) NSMutableDictionary *userInfo;
@property (assign, nonatomic) NSTimeInterval timestamp;

- (id) initWithPeer: (NSString*) peer name: (NSString*) name;
- (void) update;


@end
