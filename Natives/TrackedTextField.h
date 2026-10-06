#import <UIKit/UIKit.h>

#include "jni.h"

@interface TrackedTextField : UITextField

@property(nonatomic, copy) void(^sendChar)(jchar codepoint);
@property(nonatomic, copy) void(^sendCharMods)(jchar codepoint, int mods);
@property(nonatomic, copy) void(^sendKey)(int key, int scancode, int action, int mods);

/// Task225（反馈 #7：SDL 版输入循环根修，上游 Zalith 同款）：YES 时拒绝
/// 一切非自愿 resign（UIAsyncTextInput 每字符拆会话 / SDL text-input 更新
/// / IME 候选确认带来的临时下台——键盘不会在打字中收起）。显式收起由
/// 调用方临时置 NO 后 resign（上游 SurfaceViewController 同款包夹）。
@property(nonatomic, assign) BOOL preventUnexpectedResign;

@end
