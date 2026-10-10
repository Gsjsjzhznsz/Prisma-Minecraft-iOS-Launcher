#import "AFNetworking.h"
#import "FabricInstallViewController.h"
#import "FabricUtils.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "ProfileSettingsViewController.h"
#import "PickTextField.h"
#import "PLProfiles.h"
#import "BackgroundManager.h"
#import "PLMirrorCenter.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <objc/runtime.h>

// 添加外部全局变量声明
extern NSMutableArray *localVersionList;

@interface FabricInstallViewController()
@property(nonatomic) NSDictionary *endpoints;
@property(nonatomic) NSMutableDictionary *localKVO;
// Loader metadata
@property(nonatomic) NSArray<NSDictionary *> *loaderMetadata;
@property(nonatomic) NSMutableArray<NSString *> *loaderList;
// Game metadata
@property(nonatomic) NSArray<NSDictionary *> *versionMetadata;
@property(nonatomic) NSMutableArray<NSString *> *versionList;
// Installation state
@property(nonatomic, assign) BOOL isInstalling;
@property(nonatomic, copy) NSString *installedProfileName;
@end

@implementation FabricInstallViewController

- (void)viewDidLoad {
    // Setup navigation bar
    self.title = localize(@"profile.title.install_fabric_quilt", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // 适配自定义启动器背景（参照 ForgeInstallViewController）
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    // 监听背景效果变化通知，实时刷新毛玻璃
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // Setup appearance
    self.prefSectionsVisible = YES;

    // Setup preference getter and setter
    __weak __typeof(self) weakSelf = self;
    
    // Use preset gameVersion if provided (from DownloadViewController)
    NSString *initialGameVersion = self.gameVersion ?: @"1.20.1";
    
    self.localKVO = @{
        @"gameVersion": initialGameVersion,
        @"loaderVendor": @"Fabric",
        @"loaderVersion": @"" // 初始为空，等待网络获取后填充
    }.mutableCopy;
    self.getPreference = ^id(NSString *section, NSString *key){
        return weakSelf.localKVO[key];
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value){
        weakSelf.localKVO[key] = value;
    };

    id typePickSegment = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISegmentedControl *view = [[UISegmentedControl alloc] initWithItems:item[@"pickList"]];
        [view addTarget:weakSelf action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        if (view.selectedSegmentIndex == UISegmentedControlNoSegment) {
            view.selectedSegmentIndex = 0;
        }
        cell.accessoryView = view;
    };

    self.versionList = [NSMutableArray new];
    self.loaderList = [NSMutableArray new];
    self.prefContents = @[
        @[
            @{@"key": @"gameType",
              @"icon": @"ladybug",
              @"title": @"preference.profile.title.version_type",
              @"type": typePickSegment,
              @"pickList": @[localize(@"Release", nil), localize(@"Snapshot", nil)],
              @"action": ^(int type) {
                  [weakSelf changeVersionTypeTo:type];
              }
            },
            @{@"key": @"gameVersion",
              @"icon": @"archivebox",
              @"title": @"preference.profile.title.version",
              @"type": self.typePickField,
              @"pickKeys": self.versionList,
              @"pickList": self.versionList
            },
            @{@"key": @"loaderVendor",
              @"icon": @"folder.badge.gearshape",
              @"title": @"preference.profile.title.loader_vendor",
              @"type": typePickSegment,
              @"pickList": @[@"Fabric", @"Quilt"],
              @"action": ^(int vendor){
                  [weakSelf fetchVersionEndpoints:vendor];
              }
            },
            @{@"key": @"loaderType",
              @"icon": @"ladybug",
              @"title": @"preference.profile.title.loader_type",
              @"type": typePickSegment,
              @"pickList": @[localize(@"Release", nil), @"Unstable"],
              @"action": ^(int type) {
                  [weakSelf changeLoaderTypeTo:type];
              }
            },
            @{@"key": @"loaderVersion",
              @"icon": @"doc.badge.gearshape",
              @"title": @"preference.profile.title.loader_version",
              @"type": self.typePickField,
              @"pickKeys": self.loaderList,
              @"pickList": self.loaderList
            }
        ]
    ];

    // Ensure views are loaded here
    [super viewDidLoad];

    // Init endpoint info
    self.endpoints = FabricUtils.endpoints;
    [self fetchVersionEndpoints:0];
}

- (void)fetchVersionEndpoints:(int)type {
    // Fetch version
    __block BOOL errorShown = NO;
    id errorCallback = ^(NSURLSessionTask *operation, NSError *error) {
        if (!errorShown) {
            errorShown = YES;
            NSDebugLog(@"Error: %@", error);
            showDialog(localize(@"Error", nil), error.localizedDescription);
            [self actionClose];
        }
    };
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    [manager GET:endpoint[@"game"] parameters:nil headers:nil progress:nil  success:^(NSURLSessionTask *task, NSArray *response) {
        NSDebugLog(@"[%@ Installer] Got %d game versions", self.localKVO[@"loaderVendor"], (int)response.count);
        self.versionMetadata = response;
        [self changeVersionTypeTo:[self.localKVO[@"gameType_index"] intValue]];
    } failure:errorCallback];
    [manager GET:endpoint[@"loader"] parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        NSDebugLog(@"[%@ Installer] Got %d loader versions", self.localKVO[@"loaderVendor"], (int)response.count);
        self.loaderMetadata = response;
        [self changeLoaderTypeTo:[self.localKVO[@"loaderType_index"] intValue]];
    } failure:errorCallback];
}

- (void)actionClose {
    // If there's a completion handler, call it with cancelled status
    if (self.completionHandler) {
        self.completionHandler(NO, nil, nil);
    }
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshBackgroundEffect {
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)actionDone:(UIBarButtonItem *)sender {
    if (self.isInstalling) return;
    self.isInstalling = YES;
    sender.enabled = NO;

    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    NSString *path = [NSString stringWithFormat:endpoint[@"json"], self.localKVO[@"gameVersion"], self.localKVO[@"loaderVersion"]];
    NSDebugLog(@"[%@ Installer] Downloading %@", self.localKVO[@"loaderVendor"], path);

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    __weak typeof(self) weakSelf = self;
    [manager GET:path parameters:nil headers:nil progress:nil  success:^(NSURLSessionTask *task, NSDictionary *response) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        strongSelf.isInstalling = NO;
        sender.enabled = YES;

        NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), response[@"id"], response[@"id"]];
        [NSFileManager.defaultManager createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *error = saveJSONToFile(response, jsonPath);
        if (error) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
            if (strongSelf.completionHandler) {
                strongSelf.completionHandler(NO, nil, error);
            }
            return;
        }

        [localVersionList addObject:@{
            @"id": response[@"id"],
            @"type": @"custom"}];

        strongSelf.installedProfileName = response[@"id"];

        // 关键：在拉取 Fabric API 之前先注册并选中新 profile，
        // 否则 installFabricAPIWithCompletion 会读到旧 profile 的 gameDir，把 Fabric API 放到错误目录
        NSMutableDictionary *profile = [NSMutableDictionary dictionary];
        profile[@"name"] = response[@"id"];
        profile[@"lastVersionId"] = response[@"id"];
        // ★ Task242（用户："安装模组端的时候为什么不会自动开启版本隔离"）：
        //   Fabric 直装自动开版本隔离（原实现连 gameDir 都未写 = 共享根）；
        //   后续 installFabricAPIWithCompletion 读本 profile 的 gameDir
        //   会直接落隔离目录（语义正确：API 属于该实例）。
        profile[@"gameDir"] = [NSString stringWithFormat:@"versions/%@/game", response[@"id"]];
        profile[@"type"] = @"custom";
        profile[@"created"] = [NSDate date].description;
        [PLProfiles.current saveProfile:profile withName:response[@"id"]];
        PLProfiles.current.selectedProfileName = response[@"id"];

        // If Fabric API installation is requested
        if (strongSelf.shouldInstallAPI && [strongSelf.localKVO[@"loaderVendor"] isEqualToString:@"Fabric"]) {
            [strongSelf installFabricAPIWithCompletion:^(BOOL success, NSError *apiError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf handleInstallationComplete:response[@"id"] endpoint:endpoint error:apiError];
                });
            }];
        } else {
            [strongSelf handleInstallationComplete:response[@"id"] endpoint:endpoint error:nil];
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf.isInstalling = NO;
            sender.enabled = YES;
        }
        NSDebugLog(@"Error: %@", error);
        showDialog(localize(@"Error", nil), error.localizedDescription);
        if (strongSelf.completionHandler) {
            strongSelf.completionHandler(NO, nil, error);
        }
    }];
}

- (void)handleInstallationComplete:(NSString *)profileId endpoint:(NSDictionary *)endpoint error:(NSError *)error {
    if (error) {
        if (self.completionHandler) {
            self.completionHandler(NO, nil, error);
        }
        return;
    }

    if (self.completionHandler) {
        // New mode: profile 已在 actionDone: 中注册并选中，直接回调调用方
        self.completionHandler(YES, profileId, nil);
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else {
        // Legacy mode: jump to profile editor (使用 ProfileSettingsViewController)
        ProfileSettingsViewController *vc = [ProfileSettingsViewController new];
        vc.profileName = profileId;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)installFabricAPIWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    NSString *gameVersion = self.localKVO[@"gameVersion"];
    
    // Fabric API download URL from Modrinth（经 PLMirrorCenter 按资源搜索策略应用镜像）
    NSString *originalAPIURL = [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/fabric-api/version?game_versions=[\"%@\"]&loaders=[\"fabric\"]", gameVersion];
    NSString *apiUrl = [PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:originalAPIURL]
                                                     resourceType:PLMirrorResourceTypeAssetSearch].absoluteString ?: originalAPIURL;
    
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:apiUrl parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        if (response.count == 0) {
            NSDebugLog(@"[Fabric Installer] No Fabric API version found for game version %@", gameVersion);
            if (completion) completion(YES, nil); // Not an error, just no API available
            return;
        }
        
        // Get the latest version
        NSDictionary *latestVersion = response.firstObject;
        NSArray *files = latestVersion[@"files"];
        NSDictionary *primaryFile = nil;
        for (NSDictionary *file in files) {
            if ([file[@"primary"] boolValue]) {
                primaryFile = file;
                break;
            }
        }
        
        if (!primaryFile) {
            primaryFile = files.firstObject;
        }
        
        NSString *downloadUrl = primaryFile[@"url"];
        NSString *fileName = primaryFile[@"filename"];
        
        // 获取 mods 文件夹路径（参考 ModService.m 的 existingModsFolderForProfile: 逻辑）
        // 1. 优先读取 profile 的 gameDir，拼接 /mods
        // 2. 若 profile 无 gameDir 或 gameDir 为 "."，回退到 $POJAV_GAME_DIR/mods
        NSString *instanceName = PLProfiles.current.selectedProfileName ?: @"default";
        NSString *modsPath = nil;

        @try {
            NSDictionary *profiles = PLProfiles.current.profiles;
            NSDictionary *prof = profiles[instanceName];
            if ([prof isKindOfClass:[NSDictionary class]]) {
                NSString *profGameDir = prof[@"gameDir"];
                if ([profGameDir isKindOfClass:[NSString class]] && profGameDir.length > 0 && ![profGameDir isEqualToString:@"."]) {
                    const char *env = getenv("POJAV_GAME_DIR");
                    NSString *baseDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
                    if ([profGameDir isAbsolutePath]) {
                        modsPath = [profGameDir stringByAppendingPathComponent:@"mods"];
                    } else {
                        modsPath = [[baseDir stringByAppendingPathComponent:profGameDir] stringByAppendingPathComponent:@"mods"];
                    }
                }
            }
        } @catch (NSException *ex) { }

        if (!modsPath) {
            const char *env = getenv("POJAV_GAME_DIR");
            NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
            modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        }

        // Ensure mods directory exists
        [[NSFileManager defaultManager] createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:nil];
        
        NSURL *url = [NSURL URLWithString:downloadUrl];
        NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                NSDebugLog(@"[Fabric Installer] Failed to download Fabric API: %@", error);
                if (completion) completion(NO, error);
                return;
            }
            
            NSString *destPath = [modsPath stringByAppendingPathComponent:fileName];
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:nil];
            NSDebugLog(@"[Fabric Installer] Fabric API installed: %@", destPath);
            if (completion) completion(YES, nil);
        }];
        
        [downloadTask resume];
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[Fabric Installer] Failed to fetch Fabric API versions: %@", error);
        // Not a critical error, continue with installation
        if (completion) completion(YES, nil);
    }];
}

- (void)changeTypeToStable:(BOOL)stable forList:(NSMutableArray *)list fromMetadata:(NSArray *)metadata atRow:(int)row key:(NSString *)key {
    [list removeAllObjects];

    for (NSDictionary *version in metadata) {
        if (version[@"stable"]) {
            // Fabric: has stable key
            if ([version[@"stable"] boolValue] != stable) continue;
        } else {
            // Quilt: has beta in the version name
            if ([version[@"version"] containsString:@"beta"] == stable) continue;
        }
        [list addObject:version[@"version"]];
    }
    // 按版本号降序排序（新版本在前）
    [list sortUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
        return [v2 compare:v1 options:NSNumericSearch];
    }];
    self.localKVO[key] = list.firstObject;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)changeLoaderTypeTo:(int)type {
    [self changeTypeToStable:type==0 forList:self.loaderList fromMetadata:self.loaderMetadata atRow:4 key:@"loaderVersion"];
}
- (void)changeVersionTypeTo:(int)type {
    [self changeTypeToStable:type==0 forList:self.versionList fromMetadata:self.versionMetadata atRow:1 key:@"gameVersion"];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    self.localKVO[item[@"key"]] = [sender titleForSegmentAtIndex:sender.selectedSegmentIndex];
    self.localKVO[[item[@"key"] stringByAppendingString:@"_index"]] = @(sender.selectedSegmentIndex);
    void(^invokeAction)(int selected) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.selectedSegmentIndex);
    }
}

@end