//
//  AIInputBarView.m
//  Prisma
//

#import "AIInputBarView.h"
#import "LauncherPreferences.h"
#import "../utils.h"   // Task193：ame193 i18n 迁移需要 localize()

/// 输入胶囊高度
static const CGFloat kInputFieldHeight = 38.0;
/// 模型标签高度
static const CGFloat kModelLabelHeight = 14.0;
/// 栏上/下内边距
static const CGFloat kBarTopPadding = 2.0;
static const CGFloat kBarBottomPadding = 2.0;
/// 按钮尺寸
static const CGFloat kSendButtonSize = 40.0;
/// 水平外边距
static const CGFloat kBarHMargin = 16.0;

@interface AIInputBarView ()
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong, readwrite) UILabel *modelLabel;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@end

@implementation AIInputBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = [UIColor clearColor];
    _bottomInset = 0;

    // 模型名称标签
    self.modelLabel = [[UILabel alloc] init];
    self.modelLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.modelLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    self.modelLabel.textColor = [UIColor secondaryLabelColor];
    self.modelLabel.textAlignment = NSTextAlignmentCenter;
    self.modelLabel.numberOfLines = 1;
    self.modelLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(modelLabelTapped)];
    [self.modelLabel addGestureRecognizer:tap];
    [self addSubview:self.modelLabel];

    // 输入胶囊
    self.inputField = [[UITextField alloc] init];
    self.inputField.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputField.borderStyle = UITextBorderStyleNone;
    self.inputField.placeholder = localize(@"ame193.ai.8", @"给 Prisma 发送消息…");
    self.inputField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.inputField.textColor = [UIColor labelColor];
    self.inputField.font = [UIFont systemFontOfSize:16];
    self.inputField.autocorrectionType = UITextAutocorrectionTypeDefault;
    self.inputField.enablesReturnKeyAutomatically = YES;
    self.inputField.returnKeyType = UIReturnKeySend;
    [self.inputField addTarget:self action:@selector(textFieldDidChange) forControlEvents:UIControlEventEditingChanged];
    self.inputField.clearsOnBeginEditing = NO;
    self.inputField.leftViewMode = UITextFieldViewModeAlways;
    self.inputField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, kInputFieldHeight)];
    // 连续圆角胶囊
    self.inputField.layer.cornerRadius = kInputFieldHeight / 2.0;
    self.inputField.layer.cornerCurve = kCACornerCurveContinuous;
    self.inputField.layer.masksToBounds = YES;
    [self addSubview:self.inputField];

    // 发送/停止按钮
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sendButton.tintColor = accentColor();
    [self.sendButton setImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"] forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(sendButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.sendButton];

    // 约束（自顶向下堆叠，栏高由 heightConstraint 决定）
    [NSLayoutConstraint activateConstraints:@[
        [self.modelLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:kBarTopPadding],
        [self.modelLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.modelLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [self.modelLabel.heightAnchor constraintEqualToConstant:kModelLabelHeight],

        [self.inputField.topAnchor constraintEqualToAnchor:self.modelLabel.bottomAnchor constant:2],
        [self.inputField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kBarHMargin],
        [self.inputField.heightAnchor constraintEqualToConstant:kInputFieldHeight],

        [self.sendButton.leadingAnchor constraintEqualToAnchor:self.inputField.trailingAnchor constant:8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-kBarHMargin],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:self.inputField.centerYAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:kSendButtonSize],
        [self.sendButton.heightAnchor constraintEqualToConstant:kSendButtonSize],
    ]];

    // 栏高度 = 顶部 + 标签 + 间距 + 输入框 + 底间距 + bottomInset
    CGFloat baseHeight = kBarTopPadding + kModelLabelHeight + 2 + kInputFieldHeight + kBarBottomPadding;
    self.heightConstraint = [self.heightAnchor constraintEqualToConstant:baseHeight];
    [self.heightConstraint setActive:YES];
}

- (void)setBottomInset:(CGFloat)bottomInset {
    _bottomInset = bottomInset;
    if (self.heightConstraint) {
        CGFloat base = kBarTopPadding + kModelLabelHeight + 2 + kInputFieldHeight + kBarBottomPadding;
        self.heightConstraint.constant = base + bottomInset;
    }
}

- (void)setIsSending:(BOOL)isSending {
    _isSending = isSending;
    UIColor *accent = accentColor();
    if (isSending) {
        [self.sendButton setImage:[UIImage systemImageNamed:@"stop.circle.fill"] forState:UIControlStateNormal];
        self.sendButton.tintColor = [UIColor systemRedColor];
    } else {
        [self.sendButton setImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"] forState:UIControlStateNormal];
        self.sendButton.tintColor = accent;
    }
}

- (NSString *)text {
    return self.inputField.text ?: @"";
}

- (void)setText:(NSString *)text {
    self.inputField.text = text;
}

- (void)clearText {
    self.inputField.text = @"";
}

#pragma mark - Actions

- (void)textFieldDidChange {
    // 空输入时禁用发送
    NSString *trimmed = [self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.sendButton.enabled = trimmed.length > 0;
}

- (void)sendButtonTapped {
    if (self.isSending) {
        if (self.onStop) self.onStop();
        return;
    }
    NSString *trimmed = [self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    if (self.onSend) self.onSend(trimmed);
    [self.inputField resignFirstResponder];
}

- (void)modelLabelTapped {
    if (self.onModelTap) self.onModelTap();
}

@end