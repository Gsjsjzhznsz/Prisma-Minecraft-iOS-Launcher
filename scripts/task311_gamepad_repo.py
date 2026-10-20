#!/usr/bin/env python3
# Task311: 生成仓库手柄控件内容（controls/gamepads/*.json）+ index.json 追加
# gamepad 条目。映射内容与启动器内建 generateAndSaveDefaultControlForGamepad
# （Natives/customcontrols/CustomControlsUtils.m）逐键同源：
#   GLFW 常量: A=0 B=1 X=2 Y=3 LB=4 RB=5 BACK=6 START=7 LTHUMB=9 RTHUMB=10
#              DPAD_UP=11 RIGHT=12 DOWN=13 LEFT=14 LT=349 RT=350
#   键码:      SPACE=32 E=69 F=70 J=74 K=75 O=79 Q=81 ESC=256 TAB=258
#              LSHIFT=340 LCTRL=341 UNKNOWN=0
#   SPECIAL:   MOUSEPRI=-3 MOUSESEC=-4 SCROLLUP=-7 SCROLLDOWN=-8
# gamepad_switch = 面键键码按 Switch 键面标签预交换（物理 A=右=GLFW B 位）:
#   game:  a←Q b←SPACE x←F y←E
#   menu:  a←ESC b←MOUSEPRI x←LSHIFT y←MOUSESEC
import json, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
GPDIR = os.path.join(ROOT, 'controls', 'gamepads')

def btn(name, gb, kc):
    return {"name": name, "gamepad_button": gb, "keycode": kc}

# (name, gamepad_button, keycode) 与 CustomControlsUtils.m 内建默认一致
GAME_DEFAULT = [
    ("bumper_left", 4, -7), ("bumper_right", 5, -8),
    ("trigger_left", 349, -4), ("trigger_right", 350, -3),
    ("named_back", 6, 258), ("named_start", 7, 256),
    ("named_a", 0, 32), ("named_b", 1, 81), ("named_x", 2, 69), ("named_y", 3, 70),
    ("dpad_up", 11, 340), ("dpad_down", 13, 79), ("dpad_left", 14, 74), ("dpad_right", 12, 75),
    ("thumb_left", 9, 341), ("thumb_right", 10, 340),
]
MENU_DEFAULT = [
    ("bumper_left", 4, -7), ("bumper_right", 5, -8),
    ("trigger_left", 349, 0), ("trigger_right", 350, 0),
    ("named_back", 6, 0), ("named_start", 7, 0),
    ("named_a", 0, -3), ("named_b", 1, 256), ("named_x", 2, -4), ("named_y", 3, 340),
    ("dpad_up", 11, 0), ("dpad_down", 13, 79), ("dpad_left", 14, 74), ("dpad_right", 12, 75),
    ("thumb_left", 9, 0), ("thumb_right", 10, 0),
]
# Switch 面键对齐版：仅四个面键键码互换（其余逐键一致）
# FACE_SWAP[name] = (game 列表键码, menu 列表键码)
FACE_SWAP = {"named_a": (81, 256), "named_b": (32, -3),
             "named_x": (70, 340), "named_y": (69, -4)}

def swap_faces(lst, slot):
    out = []
    for name, gb, kc in lst:
        if name in FACE_SWAP:
            kc = FACE_SWAP[name][slot]
        out.append((name, gb, kc))
    return out

def make_map(game, menu):
    return {"version": 1,
            "mGameMappingList": [btn(*t) for t in game],
            "mMenuMappingList": [btn(*t) for t in menu]}

FILES = {
    "gamepad_default.json": make_map(GAME_DEFAULT, MENU_DEFAULT),
    "gamepad_switch.json": make_map(swap_faces(GAME_DEFAULT, 0), swap_faces(MENU_DEFAULT, 1)),
}

ENTRIES = {
    "gamepad_default.json": {
        "id": "gamepad_default",
        "name": "默认手柄映射 / Default",
        "author": "Prisma Team",
        "description": "与启动器内建默认手柄映射逐键一致（Xbox 位置语义）：A=跳跃 B=Q X=E Y=F，LB/RB=滚轮，LT/RT=鼠标右/左键，START=ESC。误删内建 default.json 后可由此找回。",
        "category": "gamepad",
    },
    "gamepad_switch.json": {
        "id": "gamepad_switch",
        "name": "Switch 面键对齐 / Switch aligned",
        "author": "Prisma Team",
        "description": "Switch/Pro/Joy-Con 专用：面键键码已按键面标签预交换（物理 A=跳跃、B=Q、X=E、Y=F），手柄类型保持 Xbox 即可，无需开启布局交换。菜单内物理 A=左键、B=ESC。",
        "category": "gamepad",
    },
}

def main():
    os.makedirs(GPDIR, exist_ok=True)
    idx_path = os.path.join(ROOT, 'controls', 'index.json')
    with open(idx_path, 'r', encoding='utf-8') as f:
        index = json.load(f)
    have = {e.get('id') for e in index.get('layouts', [])}
    added = 0
    for fname, data in FILES.items():
        out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
        path = os.path.join(GPDIR, fname)
        with open(path, 'w', encoding='utf-8') as f:
            f.write(out)
        size = len(out.encode('utf-8'))
        entry = dict(ENTRIES[fname])
        entry_id = entry.pop('id')
        entry.update({"version": "1", "file": "gamepads/" + fname, "size": size})
        if entry_id in have:
            print("skip (already in index):", entry_id)
            continue
        index.setdefault('layouts', []).append(entry)
        added += 1
        print("wrote %s (%d bytes) + index entry %s" % (path, size, entry_id))
    index['updated'] = "2026-10-20"
    with open(idx_path, 'w', encoding='utf-8') as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("index.json: %d layouts total (+%d gamepad)" % (len(index['layouts']), added))

if __name__ == '__main__':
    main()
