//
//  ViewController.h
//  BOMTalk
//
//  Created by Oliver Michalak on 22.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "BOMTalk.h"

@interface ViewController : UIViewController <BOMTalkDelegate>

@property (strong, nonatomic) IBOutlet UITextView *textView;
@property (strong, nonatomic) IBOutlet UIImageView *imageView;
@property (strong, nonatomic) IBOutlet UITableView *listView;

@end
