//
//  SessionPeerClass.m
//  werk01.de
//

#import "BOMTalkPeer.h"

@implementation BOMTalkPeer

- (id) initWithPeer: (NSString*) peer name: (NSString*) name {
	self = [super init];
	
	if (self) {
		_peerID = peer;
		_name = name;
		_state = BOMTalkPeerStateIdle;
		_userInfo = [[NSMutableDictionary alloc] init];
		_timestamp = [NSDate timeIntervalSinceReferenceDate];
	}
	
	return self;
}

- (void) update {
	_timestamp = [NSDate timeIntervalSinceReferenceDate];
}

- (BOOL) isEqual:(id) object {
	return [_peerID isEqual: ((BOMTalkPeer*)object).peerID];
}

- (NSUInteger) hash {
	return [_peerID hash];
}

- (NSString*) description {
	return [NSString stringWithFormat:@"%@ (%@) state:%d", _name, _peerID, _state];
}


@end
