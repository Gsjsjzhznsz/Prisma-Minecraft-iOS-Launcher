#import "PLLogOutputView.h"
#import "PLCrashView.h"
#import "AmeNativeMenu.h"   // ★ Task240：菜单全面系统原生 UIMenu 化
#import "SurfaceViewController.h"
#import "utils.h"

@interface PLLogOutputView()<UITableViewDataSource, UITableViewDelegate>
@property(nonatomic) UITableView* logTableView;
@property(nonatomic) UINavigationBar* navigationBar;
@end

@implementation PLLogOutputView
static BOOL fatalErrorOccurred;
static NSMutableArray* logLines;
static PLLogOutputView* current;

- (instancetype)initWithFrame:(CGRect)frame {
    frame.origin.y = frame.size.height;
    self = [super initWithFrame:frame];
    frame.origin.y = 0;

    logLines = [NSMutableArray new];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.hidden = YES;

    UINavigationItem *navigationItem = [[UINavigationItem alloc] init];
    navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop
            target:self action:@selector(actionToggleLogOutput)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
            target:self action:@selector(actionClearLogOutput)]
    ];
    self.navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 44)];
    self.navigationBar.items = @[navigationItem];
    self.navigationBar.topItem.title = localize(@"game.menu.log_output", nil);
    [self.navigationBar sizeToFit];
    self.navigationBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    self.logTableView = [[UITableView alloc] initWithFrame:frame];
    //self.logTableView.allowsSelection = NO;
    self.logTableView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.logTableView.backgroundColor = UIColor.clearColor;
    self.logTableView.contentInset = UIEdgeInsetsMake(self.navigationBar.frame.size.height, 0, 0, 0);
    self.logTableView.dataSource = self;
    self.logTableView.delegate = self;
    self.logTableView.layoutMargins = UIEdgeInsetsZero;
    self.logTableView.rowHeight = 20;
    self.logTableView.separatorInset = UIEdgeInsetsZero;
    self.logTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self addSubview:self.logTableView];
    [self addSubview:self.navigationBar];

    canAppendToLog = YES;
    [self actionStartStopLogOutput];

    current = self;
    return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return logLines.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.backgroundColor = UIColor.clearColor;
        //cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:16];
        cell.textLabel.textColor = UIColor.whiteColor;
    }
    cell.textLabel.text = logLines[indexPath.row];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *line = cell.textLabel.text;
    if (line.length == 0 || [line isEqualToString:@"\n"]) {
        return;
    }

    // ★ Task240：换装系统原生 UIMenu（锚定点按行；旧 actionSheet 退役）。
    // Task 64: 修复双重 localize —— 旧代码 localize(localize(@"Share")) 把翻译结果再当
    // key 查一次（英文环境碰巧自反，中文环境查"分享"落回原值，纯冗余调用）。
    [AmeNativeMenu ame240_presentMenuWithTitle:nil
                                     dictItems:@[
        @{ @"title": localize(@"Share", nil), @"handler": ^{
            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[line] applicationActivities:nil];
            activityVC.popoverPresentationController.sourceView = _navigationBar;
            activityVC.popoverPresentationController.sourceRect = _navigationBar.bounds;
            [currentVC() presentViewController:activityVC animated:YES completion:nil];
        } },
    ] sourceView:cell];
}

- (void)actionClearLogOutput {
    [logLines removeAllObjects];
    [self.logTableView reloadData];
}

- (void)actionShareLatestlog {
    NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.txt", getenv("POJAV_HOME")];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[@"latestlog.txt",
        [NSURL URLWithString:latestlogPath]] applicationActivities:nil];
    activityVC.popoverPresentationController.sourceView = self.navigationBar;
        activityVC.popoverPresentationController.sourceRect = self.navigationBar.bounds;
    [currentVC() presentViewController:activityVC animated:YES completion:nil];
}

- (void)actionStartStopLogOutput {
    canAppendToLog = !canAppendToLog;
    UINavigationItem* item = self.navigationBar.items[0];
    item.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
            canAppendToLog ? UIBarButtonSystemItemPause : UIBarButtonSystemItemPlay
        target:self action:@selector(actionStartStopLogOutput)];
}

- (void)actionToggleLogOutput {
    if (fatalErrorOccurred) {
        [UIApplication.sharedApplication performSelector:@selector(suspend)];
        dispatch_group_leave(fatalExitGroup);
        return;
    }

    UIViewAnimationOptions opt = self.hidden ? UIViewAnimationOptionCurveEaseOut : UIViewAnimationOptionCurveEaseIn;
    [UIView transitionWithView:self duration:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^(void){
        CGRect frame = self.frame;
        frame.origin.y = self.hidden ? 0 : frame.size.height;
        self.hidden = NO;
        self.frame = frame;
    } completion: ^(BOOL finished) {
        self.hidden = self.frame.origin.y != 0;
    }];
}

/// 返回启动器主界面
- (void)dismissAndReturnToLauncher {
    if (fatalErrorOccurred && fatalExitGroup != nil) {
        [UIApplication.sharedApplication performSelector:@selector(suspend)];
        dispatch_group_leave(fatalExitGroup);
    }
}

+ (void)_appendToLog:(NSString *)line {
    if (line.length == 0) {
        return;
    }

    // 通知 LanPortDetector 处理此日志行
    // LanPortDetector 会检测 MC "对局域网开放"日志中的端口号
    // 此通知是轻量的，即使 LanPortDetector 未启动也无副作用
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PLLogOutputLineNotification"
                                                        object:nil
                                                      userInfo:@{@"line": line}];

    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:logLines.count inSection:0];
    [logLines addObject:line];
    UIView.animationsEnabled = NO;
    [current.logTableView beginUpdates];
    [current.logTableView
        insertRowsAtIndexPaths:@[indexPath]
        withRowAnimation:UITableViewRowAnimationNone];
    [current.logTableView endUpdates];
    UIView.animationsEnabled = YES;

    [current.logTableView 
        scrollToRowAtIndexPath:indexPath
        atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}

+ (void)appendToLog:(NSString *)string {
    dispatch_async(dispatch_get_main_queue(), ^(void){
        NSArray *lines = [string componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
        for (NSString *line in lines) {
            [self _appendToLog:line];
        }
    });
}

+ (void)handleExitCode:(int)code {
    if (!current) return;
    
    // 如果有错误，显示新的崩溃界面
    if (code != 0) {
        fatalErrorOccurred = YES;
        canAppendToLog = NO;
        [PLCrashView showWithExitCode:code];
        return;
    }
    
    // 退出代码为0时的降级处理（正常退出）
    dispatch_async(dispatch_get_main_queue(), ^(void){
        if (current.hidden) {
            [current actionToggleLogOutput];
        }
        // Cleanup navigation bar
        UINavigationBar *navigationBar = current.navigationBar;
        navigationBar.topItem.title = [NSString stringWithFormat:
            localize(@"game.title.exit_code", nil), code];
        navigationBar.items[0].leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAction
            target:current action:@selector(actionShareLatestlog)];
        UIBarButtonItem *exitItem = navigationBar.items[0].rightBarButtonItems[0];
        navigationBar.items[0].rightBarButtonItems = nil;
        navigationBar.items[0].rightBarButtonItem = exitItem;

        if (canAppendToLog) {
            canAppendToLog = NO;
            fatalErrorOccurred = YES;
            return;
        }
        [current actionClearLogOutput];
        [self _appendToLog:@"... (latestlog.txt)"];
        NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
        NSString *linesStr = [NSString stringWithContentsOfFile:latestlogPath
            encoding:NSUTF8StringEncoding error:nil];
        NSArray *lines = [linesStr componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];

        // Print last 100 lines from latestlog.txt
        for (int i = MAX(lines.count-100, 0); i < lines.count; i++) {
            [self _appendToLog:lines[i]];
        }

        fatalErrorOccurred = YES;
    });
}

@end