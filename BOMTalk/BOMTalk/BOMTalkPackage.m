//
//  SessionPackageClass.m
//  werk01.de
//

#import "BOMTalkPackage.h"

@implementation BOMTalkPackage

- (id) init {
	return [self initWithMessage:0 atIndex:0 ofCounter:1 data:nil];
}

- (id) initWithMessage:(NSInteger) newMessageID {
	return [self initWithMessage:newMessageID atIndex:0 ofCounter:1 data:nil];
}

- (id) initWithMessage:(NSInteger) messageID atIndex:(NSUInteger) index ofCounter:(NSUInteger) counter data:(NSData*) data {
	if ((self = [super init])) {
		_messageID = messageID;
		_index = index;
		_counter = counter;
		if (data)
			_data = [[NSMutableData alloc] initWithData: data];
		else
			_data = nil;
	}
	return self;
}

- (id) initWithCoder:(NSCoder*) coder {
	self = [super init];
	_messageID = [coder decodeIntegerForKey:@"messageID"];
	_index = [coder decodeIntegerForKey:@"index"];
	_counter = [coder decodeIntegerForKey:@"counter"];
	if ([coder containsValueForKey:@"data"])
		_data = [coder decodeObjectForKey:@"data"];
	else
		_data = nil;
	return self;
}

- (void) encodeWithCoder:(NSCoder*) coder {
	[coder encodeInteger:_messageID forKey:@"messageID"];
	[coder encodeInteger:_index forKey:@"index"];
	[coder encodeInteger:_counter forKey:@"counter"];
	if (_data)
		[coder encodeObject:_data forKey:@"data"];
}

- (BOOL) appendPackage:(BOMTalkPackage*) package {
	if (_messageID == package.messageID && _index+1 == package.index) {
		[_data appendData:package.data];
		_index++;
		return YES;
	}
	return NO;
}

- (BOOL) isComplete {
	if (_index+1 == _counter)
		return YES;
	return NO;
}

- (NSString*) description {
	return [NSString stringWithFormat:@"%d: %d of %d len:%d", _messageID, _index, _counter, _data.length];
}


@end
