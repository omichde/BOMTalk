//
//  SessionPackageClass.h
//  werk01.de
//

#import <Foundation/Foundation.h>

@interface BOMTalkPackage : NSObject <NSCoding>

@property (assign, nonatomic) NSInteger messageID;
@property (strong, nonatomic) NSMutableData *data;
@property (readonly, nonatomic) BOOL isHead;
@property (readonly, nonatomic) BOOL isComplete;
@property (readonly, nonatomic) float progress;

- (id) initWithMessage:(NSInteger) messageID;
- (id) initWithMessage:(NSInteger) messageID atIndex:(NSUInteger) index ofCounter:(NSUInteger) counter data:(NSData*) data;
- (BOOL) appendPackage:(BOMTalkPackage*) package;

@end
