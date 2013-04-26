//
//  NotifyViewController.h
//  BOMTalk
//
//  Created by Oliver Michalak on 26.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface NotifyViewController : UIViewController

@property (strong, nonatomic) IBOutlet UIButton *ballView;
@property (strong, nonatomic) IBOutlet UIView *areaView;
@property (strong, nonatomic) IBOutlet UIView *racketView;
@property (strong, nonatomic) IBOutlet UISlider *slideView;
@property (strong, nonatomic) IBOutlet UITableView *listView;

- (IBAction) slide;

@end
