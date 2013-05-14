//
//  BOMTalkDebugViewController.h
//  BOMTalk
//
//  Created by Oliver Michalak on 30.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "BOMTalkDebugEvent.h"

/**
 Debugging network messaging can be a PITA, this simple view controller tries to simplify this. It displays columns of peers and the messages between thoses peers in a timeline.

 - You can zoom into the timeline by pinch gestures.
 - The messages are aligned (left or right) from the sender to the receiver or not at all for general messages.
 - Events are colored and slightly transparent for easier reading
 
 @warning This View Controller draws each event in the timeline with a new UILabel, hence with a growing number of events the timeline slows down significantly.

 @warning You can disable this view controller totally in the framework by commenting `BOMTalkDebug` in BOMTalk.h
 
 */
@interface BOMTalkDebugViewController : UIViewController

/**
 The background all views are attached to.
 */
@property (strong, nonatomic) IBOutlet UIView *backContainer;

/**
 The UIScrollView to add events to.
 */
@property (strong, nonatomic) IBOutlet UIScrollView *scrollContainer;

/**
 Adds a new event to the timeline.
 @param event New event
 */
- (void) addEvent: (BOMTalkDebugEvent*) event;

@end
