//
//  SessionPackageClass.h
//  werk01.de
//

#import <Foundation/Foundation.h>

/**
 All transmitted data for BOMTalk is encapsulated in objects of this class. The payload istself contains a small header for the message ID, the index of the current package and the number of total packages.
 */
@interface BOMTalkPackage : NSObject <NSCoding>

/**
 Your message ID.
 */
@property (assign, nonatomic) NSInteger messageID;

/**
 The data of this package.
 */
@property (strong, nonatomic) NSMutableData *data;

/**
 Wether this is the first block in a sequence of bloks.
 */
@property (readonly, nonatomic) BOOL isHead;

/**
 Wether the package waits for other data or is complete.
 */
@property (readonly, nonatomic) BOOL isComplete;

/**
 Helper property to calculate the progress metric for this package within all expected blocks.
 */
@property (readonly, nonatomic) float progress;

/**
 Creates a new empty package with the given ID.
 @param messageID The new message ID
 */
- (id) initWithMessage:(NSInteger) messageID;

/**
 Creates a new package at a specific index within the package sequence
 @param messageID The new message ID
 @param index The index of the package within the sequence
 @param counter Number of packages within the sequence
 @param data Data of this package
 */
- (id) initWithMessage:(NSInteger) messageID atIndex:(NSUInteger) index ofCounter:(NSUInteger) counter data:(NSData*) data;

/**
 Append a package data to the current package
 @param package Package to take data out of
 */
- (BOOL) appendPackage:(BOMTalkPackage*) package;

@end
