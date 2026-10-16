//
//  AIInputBarView.h
//  Prisma
//
//  AI 聊天底部输入栏：胶囊输入框 + 发送/停止切换按钮 + 模型名标签。
//  键盘与底部安全区适配由外部（AIViewController）通过 bottomInset 与键盘通知拉动。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AIInputBarView : UIView

/// 输入框文字（读取为当前输入文本）
@property (nonatomic, copy) NSString *text;
/// 底部安全区垫高（由外部随 safeAreaInsets / 键盘更新）
@property (nonatomic, assign) CGFloat bottomInset;
/// 是否正在生成（切到停止图标）
@property (nonatomic, assign) BOOL isSending;

/// 模型名展示标签（点击触发 onModelTap）
@property (nonatomic, strong, readonly) UILabel *modelLabel;

/// 发送回调
@property (nonatomic, copy, nullable) void (^onSend)(NSString *text);
/// 停止回调
@property (nonatomic, copy, nullable) void (^onStop)(void);
/// 点击模型标签回调
@property (nonatomic, copy, nullable) void (^onModelTap)(void);

/// 清空输入框
- (void)clearText;

@end

NS_ASSUME_NONNULL_END