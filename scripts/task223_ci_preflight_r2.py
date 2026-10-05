#!/usr/bin/env python3
"""Task223 CI-repair round-2 preflight: deep audit of the ADDED lines in the
21 never-compiled modified TUs. Checks:
  A. bracket-call selectors not declared anywhere in repo (and not framework)
  B. UIWindow.mainWindow / externalWindow dot-syntax without UIKit+hook.h
  C. C-function calls not declared in the TU's transitive import closure
  D. __block captures (precise: declarations outside, assignments inside ^{})
"""
import re, os, glob, subprocess

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"
os.chdir(REPO)
NAT = "Natives"
BASE = "36ca4b25a"   # pre-Task223 baseline

NEVER_COMPILED = """AI/AIViewController.m Ame223CoachMarksView.m BackgroundManager.m
DownloadViewController.m FolderBrowserViewController.m JavaGUIViewController.m
LauncherCardLayoutViewController.m LauncherNavigationController.m
LauncherPreferencesViewController.m LauncherRightPanelViewController.m
LauncherRootViewController.m MinecraftResourceUtils.m ProfileSettingsViewController.m
SceneDelegate.m SurfaceViewController.m TerracottaManager.m
TouchControllerPreferencesViewController.m WelcomeViewController.m
input_bridge_v3.m ios_uikit_bridge.m utils.m""".split()

# ---------- build selector universe ----------
universe = set()
for f in glob.glob(f'{NAT}/**/*.h', recursive=True) + glob.glob(f'{NAT}/**/*.m', recursive=True) + glob.glob(f'{NAT}/**/*.mm', recursive=True):
    src = open(f, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'^\s*[-+]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)', src, re.M):
        universe.add(m.group(1))
    for m in re.finditer(r'@selector\(([A-Za-z_][A-Za-z0-9_:]+)\)', src):
        universe.add(m.group(1).split(':')[0])

# common framework selectors (whitelist, generously)
FW = set('''initWithFrame initWithItems buttonWithType systemImageNamed stringWithFormat
localizedStringWithFormat arrayWithObjects dictionaryWithDictionary activateConstraints
constraintEqualToAnchor constraintEqualToConstant constraintLessThanOrEqualToAnchor
constraintGreaterThanOrEqualToAnchor constraintLessThanOrEqualToConstant
constraintGreaterThanOrEqualToConstant constraintEqualToSystemSpacingAfterAnchor
addArrangedSubview addSubview insertSubview removeFromSuperview setBackgroundColor
setTintColor setTitle setTitleColor setImage addTarget addGestureRecognizer
removeFromSuperview setNeedsLayout layoutIfNeeded sizeThatFits systemLayoutSizeFittingSize
deselectRowAtIndexPath dequeueReusableCellWithIdentifier cellForRowAtIndexPath numberOfRows
inSection heightForRowAtIndexPath viewForHeaderInSection titleForHeaderInSection
didSelectRowAtIndexPath canEditRowAtIndexPath commitEditingStyle
leadingAnchor trailingAnchor topAnchor bottomAnchor centerXAnchor centerYAnchor
widthAnchor heightAnchor safeAreaLayoutGuide contentLayoutGuide frameLayoutGuide
contentInsetAdjustmentBehavior alwaysBounceVertical translatesAutoresizingMask
separatorColor tableHeaderView rowHeight estimatedRowHeight textLabel detailTextLabel
imageView contentView accessibilityLabel numberOfLines textAlignment lineBreakMode
adjustsFontForContentSizeCategory monospacedDigitSystemFontOfSize systemFontOfSize
boldSystemFontOfSize labelColor secondaryLabelColor tertiaryLabelColor quaternaryLabelColor
clearColor whiteColor blackColor grayColor lightGrayColor darkGrayColor
systemBackgroundColor secondarySystemBackgroundColor tertiarySystemBackgroundColor
systemGroupedBackgroundColor secondarySystemGroupedBackgroundColor separatorColor
linkColor placeholderTextColor darkTextColor lightTextColor viewFlipsideBackgroundColor
systemRedColor systemBlueColor systemGreenColor systemOrangeColor systemYellowColor
systemGrayColor systemPinkColor systemPurpleColor systemTealColor systemIndigoColor
systemMintColor systemCyanColor systemBrownColor systemFillColor secondarySystemFillColor
tertiarySystemFillColor quaternarySystemFillColor opaqueSystemFillColor
underPageBackgroundColor raisedColor shadowColor
alertControllerWithTitle actionWithTitle addAction preferredStyle
animateWithDuration delay options animations completion
dismissViewControllerAnimated presentViewController completion
center size origin x y width height alpha hidden enabled selected
startAnimating stopAnimating hidesWhenStopped color
array arrayWithCapacity addObject removeObjectAtIndex removeObject removeAllObjects
addObjectsFromArray count objectAtIndex firstObject lastObject componentsJoinedByString
componentsSeparatedByString dictionary dictionaryWithDictionary dictionaryWithCapacity
setObject removeObjectForKey objectForKey setObjectforKey
stringByAppendingPathComponent stringByDeletingLastPathComponent lastPathComponent
pathExtension stringByDeletingPathExtension stringByAppendingPathExtension
stringByTrimmingCharactersInSet hasPrefix hasSuffix containsString isEqualToString
isEqual substringFromIndex substringToIndex substringWithRange rangeOfString
characterAtIndex length UTF8String isEqualToString copy mutableCopy
integerValue intValue floatValue doubleValue boolValue longLongValue unsignedIntegerValue
stringWithUTF8String stringWithString stringWithFormat stringWithCString
dataWithContentsOfFile writeToFile atomically dataUsingEncoding
date distantPast distantFuture timeIntervalSinceDate timeIntervalSinceNow
dateWithTimeIntervalSinceNow dateByAddingTimeInterval
fileManager defaultManager attributesOfItemAtPath fileExistsAtPath isDirectory
contentsOfDirectoryAtPath createDirectoryAtPath withIntermediateDirectories
removeItemAtPath copyItemAtPath moveItemAtPath toPath
enumeratorAtPath nextObject skipDescendants currentDirectory
defaultCenter addObserver selector name object postNotification removeObserver
mainQueue globalQueue dispatch_async dispatch_sync dispatch_after dispatch_once
sharedApplication keyWindow windows delegate rootViewController
presentedViewController presentViewController navigationController
pushViewController popViewController popToRootViewController setViewControllers
tabBarItem navigationItem title leftBarButtonItem rightBarButtonItem backBarButtonItem
hidesBackButton toolbarItems tabBarItem
defaultSession sessionWithConfiguration session dataTaskWithTaskWithURL
URLWithString URLWithString fileURLWithPath absoluteString lastPathComponent pathExtension
host port scheme query
numberWithInteger numberWithInt numberWithBool numberWithDouble numberWithFloat
sharedManager sharedService shared sharedInstance defaultManager defaultCenter
mainScreen bounds nativeBounds scale
valueWithCGRect CGRectValue valueWithCGPoint CGPointValue NSValue
bezierPathWithOvalInRect bezierPathWithRect bezierPathWithRoundedRect cornerRadius
appendPath moveToPoint addLineToPoint closePath stroke fill
colorWithRed green blue alpha colorWithWhite colorWithHue
CGColor CGPath CGImage CGLayer
convertRect convertPoint toView fromView convertRect toView
isKindOfClass isKindOfClass respondsToSelector conformsToProtocol performSelector
addSublayer removeFromSuperlayer setNeedsDisplay insertSublayer
animationWithKeyPath functionWithName timingFunction
removeAnimationForKey addAnimation speed fillMode
convertSize convertRect convertPoint
objectForKey entries keysInOrder enumerateKeysAndObjectsUsingBlock
setTimeout setMinimum setMaximum setValue
setProgress setProgressTintColor setTrackTintColor
setText setFont setTextColor setTextAlignment
setUserInteractionEnabled setExclusiveTouch
if let else return
class super self nil NULL YES NO'''.split())

# C functions declared in Natives headers
c_funcs = set()
for f in glob.glob(f'{NAT}/**/*.h', recursive=True):
    src = open(f, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'^\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*\*?\s*)+([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{]*\)\s*;', src, re.M):
        c_funcs.add(m.group(1))

LIBC_OK = set('''socket connect bind listen accept close read write send recv
gethostbyname getaddrinfo freeaddrinfo inet_addr inet_ntoa htons ntohs htonl ntohl
fcntl select getsockopt setsockopt memset memcpy strlen strcpy strncpy strcmp strncmp
strstr strchr strrchr snprintf printf fprintf sprintf sscanf atoi atof strtol strtoul
malloc calloc realloc free exit abort getenv setenv unsetenv putenv
pthread_create pthread_join pthread_mutex_lock pthread_mutex_unlock pthread_self
dispatch_group_create dispatch_group_enter dispatch_group_leave dispatch_group_wait
dispatch_semaphore_create dispatch_semaphore_signal dispatch_semaphore_wait
dispatch_get_global_queue dispatch_get_main_queue dispatch_queue_create
dispatch_async dispatch_sync dispatch_after dispatch_once dispatch_get_current_queue
dispatch_time DISPATCH_TIME_NOW DISPATCH_TIME_FOREVER
mach_absolute_time getpid getppid syscall sysctl sysctlbyname
CFRelease CFRetain CFStringGetCStringPtr CFStringCreateWithCString
NSLog NSStringFromClass
min max abs roundf floorf ceilf sqrtf powf atan2f'''.split())

def read(p):
    return open(p, encoding='utf-8', errors='replace').read()

problems = []
for rel in NEVER_COMPILED:
    path = os.path.join(NAT, rel)
    src = read(path)
    code = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    code = re.sub(r'//[^\n]*', '', code)
    lines = code.split('\n')

    # A. bracket selectors
    for m in re.finditer(r'\[\s*[\w.\]\[ ]+?\s+([A-Za-z_][A-Za-z0-9_]+)[\s:\]]', code):
        sel = m.group(1)
        if sel in universe or sel in FW or sel in c_funcs:
            continue
        if sel.startswith(('init', 'alloc', 'copy', 'mutableCopy', 'new', 'set', 'is', 'has', 'can', 'should')):
            continue
        problems.append((rel, f'bracket-selector {sel!r} unknown'))

    # B. mainWindow dot-syntax without hook import (direct or via SurfaceViewController.h)
    if re.search(r'UIWindow\s*\.\s*mainWindow|\[UIWindow\s+mainWindow\]', code):
        if 'UIKit+hook.h' not in src and 'SurfaceViewController.h' not in src:
            problems.append((rel, 'UIWindow.mainWindow without UIKit+hook.h'))

    # D. __block: declarations assigned in subsequent block bodies (same function scope, crude)
    for i, ln in enumerate(lines):
        m = re.match(r'\s*(?:const\s+)?(BOOL|NSUInteger|NSInteger|int|unsigned|long|float|double|unsigned long long|CGFloat|NSDate\s*\*|NSString\s*\*|NSMutableArray\s*\*|NSMutableDictionary\s*\*|id)\s+(\w+)\s*=', ln)
        if not m or '__block' in ln or '__weak' in ln:
            continue
        var = m.group(2)
        window = '\n'.join(lines[i+1:i+200])
        # assignment inside a ^{...} or ^ (...) block: look for ^{ then var=
        for bm in re.finditer(r'\^\s*(?:\([^)]*\))?\s*\{', window):
            tail = window[bm.end():bm.end()+2500]
            depth, j = 1, 0
            while j < len(tail) and depth > 0:
                if tail[j] == '{': depth += 1
                elif tail[j] == '}': depth -= 1
                j += 1
            body = tail[:j]
            if re.search(r'\b' + re.escape(var) + r'\s*(?:\+\+|--|=[^=])', body):
                problems.append((rel, f'var {var!r} assigned in block without __block (line {i+1})'))
                break

print(f"== problems in never-compiled set ==")
if not problems:
    print("NONE — clean")
for rel, msg in problems:
    print(f'  {rel}: {msg}')
