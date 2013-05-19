//
//  SessionPeerClass.m
//  werk01.de
//

#import "BOMTalkPeer.h"

@implementation BOMTalkPeer

- (id) initWithPeer: (NSString*) peer name: (NSString*) name {
	self = [super init];
	
	if (self) {
		self.peerID = peer;
		self.name = name;
		self.state = BOMTalkPeerStateIdle;
		self.userInfo = [[NSMutableDictionary alloc] init];
		self.timestamp = [NSDate timeIntervalSinceReferenceDate];
	}
	
	return self;
}

- (void) update {
	self.timestamp = [NSDate timeIntervalSinceReferenceDate];
}

- (BOOL) isEqual:(id) object {
	return [self.peerID isEqual: ((BOMTalkPeer*)object).peerID];
}

- (NSUInteger) hash {
	return [self.peerID hash];
}

- (NSString*) description {
	return [NSString stringWithFormat:@"%@ (%@) state:%d, userInfo: %@", self.name, self.peerID, self.state, self.userInfo];
}


@end
