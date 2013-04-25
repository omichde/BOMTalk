//
//  SessionPackageClass.h
//  werk01.de
//

#import <Foundation/Foundation.h>

@interface BOMTalkPackage : NSObject <NSCoding>

@property (assign, nonatomic) NSInteger messageID;
@property (assign, nonatomic) NSInteger index;
@property (assign, nonatomic) NSInteger counter;
@property (strong, nonatomic) NSMutableData *data;
@property (readonly, nonatomic) BOOL isComplete;

- (id) initWithMessage:(NSInteger) messageID;
- (id) initWithMessage:(NSInteger) messageID atIndex:(NSUInteger) index ofCounter:(NSUInteger) counter data:(NSData*) data;
- (BOOL) appendPackage:(BOMTalkPackage*) package;

@end
