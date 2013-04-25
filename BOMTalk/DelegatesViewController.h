//
//  DelegatesViewController.h
//  BOMTalk
//
//  Created by Oliver Michalak on 24.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "BOMTalk.h"

@interface DelegatesViewController : UIViewController <BOMTalkDelegate>

@property (strong, nonatomic) IBOutlet UILabel *numberView;
@property (strong, nonatomic) IBOutlet UIButton *rollButton;
@property (strong, nonatomic) IBOutlet UIActivityIndicatorView *loadingView;
@property (strong, nonatomic) IBOutlet UILabel *infoView;

- (IBAction)roll;

@end
