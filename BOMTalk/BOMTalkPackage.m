//
//  SessionPackageClass.m
//  werk01.de
//

#import "BOMTalkPackage.h"

@interface BOMTalkPackage ()
@property (assign, nonatomic) NSInteger index;
@property (assign, nonatomic) NSInteger counter;
@end

@implementation BOMTalkPackage

- (id) init {
	return [self initWithMessage:0 atIndex:0 ofCounter:1 data:nil];
}

- (id) initWithMessage:(NSInteger) newMessageID {
	return [self initWithMessage:newMessageID atIndex:0 ofCounter:1 data:nil];
}

- (id) initWithMessage:(NSInteger) messageID atIndex:(NSUInteger) index ofCounter:(NSUInteger) counter data:(NSData*) data {
	if ((self = [super init])) {
		self.messageID = messageID;
		self.index = index;
		self.counter = counter;
		if (data)
			self.data = [[NSMutableData alloc] initWithData: data];
		else
			self.data = nil;
	}
	return self;
}

- (id) initWithCoder:(NSCoder*) coder {
	self = [super init];
	self.messageID = [coder decodeIntegerForKey:@"messageID"];
	self.index = [coder decodeIntegerForKey:@"index"];
	self.counter = [coder decodeIntegerForKey:@"counter"];
	if ([coder containsValueForKey:@"data"])
		self.data = [coder decodeObjectForKey:@"data"];
	else
		self.data = nil;
	return self;
}

- (void) encodeWithCoder:(NSCoder*) coder {
	[coder encodeInteger:self.messageID forKey:@"messageID"];
	[coder encodeInteger:self.index forKey:@"index"];
	[coder encodeInteger:self.counter forKey:@"counter"];
	if (self.data)
		[coder encodeObject:self.data forKey:@"data"];
}

- (BOOL) appendPackage:(BOMTalkPackage*) package {
	if (self.messageID == package.messageID && self.index+1 == package.index) {
		[self.data appendData:package.data];
		self.index++;
		return YES;
	}
	return NO;
}

- (BOOL) isHead {
	return (!self.index);
}

- (BOOL) isComplete {
	if (self.index+1 == self.counter)
		return YES;
	return NO;
}

- (float) progress {
	return ((float) self.index+1) / (float) self.counter;
}

- (NSString*) description {
	return [NSString stringWithFormat:@"%d: %d of %d len:%d", self.messageID, self.index, self.counter, self.data.length];
}


@end
