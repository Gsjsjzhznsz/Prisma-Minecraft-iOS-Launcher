#import "ControlDrawer.h"
#import "CustomControlsUtils.h"
#import "../LauncherPreferences.h"
#import "../utils.h"

#define DOWN 0
#define LEFT 1
#define UP 2
#define RIGHT 3

@implementation ControlDrawer

+ (id)buttonWithData:(NSMutableDictionary *)drawerData {
    ControlDrawer *instance = [self buttonWithProperties:drawerData[@"properties"]];
    instance.buttons = [[NSMutableArray alloc] init];
    instance.drawerData = drawerData;

    return instance;
}

- (ControlSubButton *)addButton:(ControlSubButton *)button {
    [self.buttons addObject:button];
    button.parentDrawer = self;
    button.hidden = !isControlModifiable;
    return button;
}

- (void)restoreButtonVisibility {
    // ★ Task233（反馈 #1 纠偏）：子按钮可见性此前只看 areButtonsVisible——
    //   抽屉本体被 displayInMenu/displayInGame/hide-all 规则隐藏时，散点
    //   子按钮仍可能滞留屏上挡触摸（"有时必须开着抽屉才能用键"的状态机
    //   脱钩来源）。此处叠加抽屉自身 hidden：抽屉不在场 = 键一律收起。
    for (ControlButton *button in self.buttons) {
        button.hidden = self.hidden || !self.areButtonsVisible;
    }
}

- (void)switchButtonVisibility {
    self.areButtonsVisible = !self.areButtonsVisible;
    [self restoreButtonVisibility];
}

// NOTE: Unlike Android's impl, this method uses dp instead of px (no call to dpToPx)
- (void)alignButtons {
    NSString *orientation = (NSString *)self.drawerData[@"orientation"];

    for (int i = 0; i < self.buttons.count; i++) {
        ControlButton *button = self.buttons[i];
        if ([orientation isEqualToString:@"FREE"]) {
            // Do nothing but call update
        } else if ([orientation isEqualToString:@"RIGHT"]) {
            button.properties[@"dynamicX"] = [self generateDynamicX:self.frame.origin.x + ([self.properties[@"width"] floatValue] + 2.0) * (i+1)];
            button.properties[@"dynamicY"] = [self generateDynamicY:self.frame.origin.y];
        } else if ([orientation isEqualToString:@"LEFT"]) {
            button.properties[@"dynamicX"] = [self generateDynamicX:self.frame.origin.x - ([self.properties[@"width"] floatValue] + 2.0) * (i+1)];
            button.properties[@"dynamicY"] = [self generateDynamicY:self.frame.origin.y];
        } else if ([orientation isEqualToString:@"UP"]) {
            button.properties[@"dynamicY"] = [self generateDynamicY:self.frame.origin.y - ([self.properties[@"height"] floatValue] + 2.0) * (i+1)];
            button.properties[@"dynamicX"] = [self generateDynamicX:self.frame.origin.x];
        } else if ([orientation isEqualToString:@"DOWN"]) {
            button.properties[@"dynamicY"] = [self generateDynamicY:self.frame.origin.y + ([self.properties[@"height"] floatValue] + 2.0) * (i+1)];
            button.properties[@"dynamicX"] = [self generateDynamicX:self.frame.origin.x];
        } else {
            NSLog(@"DEBUG: %s: Unsupported button orientation %@", __FILE__, orientation);
        }
        [button update];
    }
}

- (void)resizeButtons {
    NSString *orientation = (NSString *)self.drawerData[@"orientation"];
    if ([orientation isEqualToString:@"FREE"]) {
        return;
    }

    for (ControlButton *button in self.buttons) {
        button.properties[@"width"] = self.properties[@"width"];
        button.properties[@"height"] = self.properties[@"height"];
        [button update];
    }
}

- (void)syncButtons {
    [self alignButtons];
    [self resizeButtons];
}

- (void)update {
    [super update];
    [self syncButtons];
}

- (BOOL)containsChild:(ControlButton *)button {
    return [self.buttons containsObject:button];
}

- (void)preProcessProperties {
    [super preProcessProperties];
}

/*
- (void)setHidden:(BOOL)hidden {
    super
}
*/

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    [super touchesEnded:touches withEvent:event];
    if (!isControlModifiable) {
        [self switchButtonVisibility];
    }
}

- (BOOL)canSnap:(ControlButton *)button {
    return [super canSnap:button] && ![self containsChild:button];
}

- (void)snapAndAlignX:(CGFloat)x Y:(CGFloat)y {
    [super snapAndAlignX:x Y:y];
    [self alignButtons];
}

@end
