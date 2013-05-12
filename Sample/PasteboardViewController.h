//
//  BlocksViewController.h
//  BOMTalk
//
//  Created by Oliver Michalak on 24.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface PasteboardViewController : UIViewController

@property (strong, nonatomic) IBOutlet UITextView *textView;
@property (strong, nonatomic) IBOutlet UIImageView *imageView;
@property (strong, nonatomic) IBOutlet UITableView *listView;

@end
