//
//  BOMTalkDebugViewController.h
//  BOMTalk
//
//  Created by Oliver Michalak on 30.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "BOMTalkDebugEvent.h"

@interface BOMTalkDebugViewController : UIViewController

@property (strong, nonatomic) IBOutlet UIView *backContainer;
@property (strong, nonatomic) IBOutlet UIScrollView *scrollContainer;

- (void) addEvent: (BOMTalkDebugEvent*) event;

@end
