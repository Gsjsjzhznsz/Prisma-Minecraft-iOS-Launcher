//
//  BingWallpaperGalleryViewController.m
//  Amethyst
//
//  Task151：Bing 壁纸库画廊实现。
//  数据源 = BingWallpaperManager.items（HPImageArchive 近 8 天）。
//  交互：点按条目 → 操作面板（设为壁纸 / 保存到相册）；导航栏刷新按钮
//  重新拉取元数据；当前已应用条目显示勾选；全部失败路径有用户可见反馈。
//

#import "BingWallpaperGalleryViewController.h"
#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化
#import "BingWallpaperManager.h"
#import "BackgroundManager.h"
#import "utils.h"

static NSString * const kBingCellIdentifier = @"BingWallpaperCell";

@interface BingWallpaperCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation BingWallpaperCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.layer.cornerRadius = 10;
        self.contentView.layer.masksToBounds = YES;

        _thumbView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, frame.size.width * 9.0 / 16.0)];
        _thumbView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        _thumbView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
        [self.contentView addSubview:_thumbView];

        _dateLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, _thumbView.frame.size.height + 4, frame.size.width - 16, 14)];
        _dateLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _dateLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
        _dateLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:_dateLabel];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, _thumbView.frame.size.height + 20, frame.size.width - 16, 30)];
        _titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _titleLabel.font = [UIFont systemFontOfSize:12];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.numberOfLines = 2;
        [self.contentView addSubview:_titleLabel];
    }
    return self;
}

@end

@interface BingWallpaperGalleryViewController () <UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) NSArray<BingWallpaperItem *> *items;
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation BingWallpaperGalleryViewController

+ (UICollectionViewController *)galleryController {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    return [[BingWallpaperGalleryViewController alloc] initWithCollectionViewLayout:layout];
}

- (instancetype)initWithCollectionViewLayout:(UICollectionViewLayout *)layout {
    self = [super initWithCollectionViewLayout:layout];
    if (self) {
        self.title = localize(@"bing.gallery.nav.title", nil);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.collectionView.backgroundColor = [UIColor systemBackgroundColor];
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:[BingWallpaperCell class] forCellWithReuseIdentifier:kBingCellIdentifier];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self
                                                                                           action:@selector(refreshTapped)];

    // 空态提示（首启离线且从未同步时可见）
    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.text = localize(@"bing.status.unsynced", nil);
    self.emptyLabel.font = [UIFont systemFontOfSize:14];
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];

    [self reloadItemsAnimated:NO];

    // 元数据刷新完成 → 重载画廊
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBingUpdate)
                                                 name:BingWallpaperDidUpdateNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadItemsAnimated:NO];
}

- (void)handleBingUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadItemsAnimated:YES];
    });
}

- (void)reloadItemsAnimated:(BOOL)animated {
    self.items = [BingWallpaperManager sharedManager].items;
    self.emptyLabel.hidden = self.items.count > 0;
    [self.collectionView reloadData];

    // 首次进入且无缓存：自动补一次同步
    if (self.items.count == 0 && ![BingWallpaperManager sharedManager].lastSyncDate) {
        [[BingWallpaperManager sharedManager] refreshWithCompletion:nil];
    }
}

#pragma mark - Actions

- (void)refreshTapped {
    __weak typeof(self) weakSelf = self;
    [[BingWallpaperManager sharedManager] refreshWithCompletion:^(BOOL success, NSError *_Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                       message:success ? localize(@"bing.refresh.done", nil)
                                                                                       : localize(@"bing.refresh.failed", nil)
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [strongSelf presentViewController:alert animated:YES completion:nil];
    }];
}

#pragma mark - UICollectionView Data Source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.items.count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = self.view.bounds.size.width;
    NSInteger columns = width > 700 ? 4 : (width > 480 ? 3 : 2);
    CGFloat spacing = 12;
    CGFloat itemWidth = floor((width - 16 * 2 - spacing * (columns - 1)) / columns);
    CGFloat imageHeight = itemWidth * 9.0 / 16.0;
    return CGSizeMake(itemWidth, imageHeight + 52);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    return UIEdgeInsetsMake(12, 16, 12, 16);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    return 12;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    return 14;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BingWallpaperCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kBingCellIdentifier forIndexPath:indexPath];
    BingWallpaperItem *item = self.items[indexPath.item];

    // 日期格式化：yyyyMMdd → 本地短日期
    static NSDateFormatter *parse = nil;
    static NSDateFormatter *display = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        parse = [[NSDateFormatter alloc] init];
        parse.dateFormat = @"yyyyMMdd";
        parse.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        display = [[NSDateFormatter alloc] init];
        display.dateStyle = NSDateFormatterMediumStyle;
        display.timeStyle = NSDateFormatterNoStyle;
    });
    NSDate *date = [parse dateFromString:item.startdate];
    cell.dateLabel.text = date ? [display stringFromDate:date] : item.startdate;
    cell.titleLabel.text = item.title.length > 0 ? item.title : item.copyright;

    // 缩略图：内存命中直填，否则异步加载（仅当 cell 仍归属该 indexPath 时回填）
    UIImage *cached = [[BingWallpaperManager sharedManager] cachedThumbnailForItem:item];
    if (cached) {
        cell.thumbView.image = cached;
    } else {
        cell.thumbView.image = nil;
        __weak UICollectionView *weakCV = collectionView;
        [[BingWallpaperManager sharedManager] thumbnailForItem:item completion:^(UIImage *_Nullable image) {
            UICollectionView *strongCV = weakCV;
            if (!image || !strongCV) return;
            NSIndexPath *visibleIndex = [strongCV indexPathForCell:cell];
            if (visibleIndex && [visibleIndex isEqual:indexPath]) {
                cell.thumbView.image = image;
            }
        }];
    }

    // 当前应用项勾选
    BOOL applied = [self isItemApplied:item];
    cell.contentView.layer.borderWidth = applied ? 2.0 : 0.0;
    cell.contentView.layer.borderColor = applied ? [UIColor systemBlueColor].CGColor : nil;

    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    BingWallpaperItem *item = self.items[indexPath.item];
    [self showItemActions:item sourceCell:[collectionView cellForItemAtIndexPath:indexPath]];
}

#pragma mark - Item Actions（设为壁纸 / 保存到相册）

- (BOOL)isItemApplied:(BingWallpaperItem *)item {
    BackgroundManager *bg = [BackgroundManager sharedManager];
    if (![bg hasImageBackground] || !bg.currentBackgroundPath) return NO;
    NSString *fileName = bg.currentBackgroundPath.lastPathComponent;
    return [fileName hasPrefix:item.startdate];
}

- (void)showItemActions:(BingWallpaperItem *)item sourceCell:(nullable UICollectionViewCell *)cell {
    // ★ Task240：换装系统原生 UIMenu（旧 actionSheet 退役；版权/标题
    // 信息以禁用头行保留）。
    NSMutableArray<NSDictionary *> *ame240_items = [NSMutableArray array];
    [ame240_items addObject:@{
        @"title": [NSString stringWithFormat:@"%@\n%@", item.copyright ?: @"", item.title ?: @""],
        @"disabled": @YES,
    }];

    __weak typeof(self) weakSelf = self;
    [ame240_items addObject:@{
        @"title": localize(@"bing.setwallpaper.title", nil),
        @"handler": ^{ [weakSelf applyItem:item]; },
    }];

    [ame240_items addObject:@{
        @"title": localize(@"bing.save.title", nil),
        @"handler": ^{ [weakSelf saveItemToPhotos:item]; },
    }];

    [AmeNativeMenu ame240_presentMenuWithTitle:localize(@"bing.gallery.nav.title", nil)
                                     dictItems:ame240_items
                                    sourceView:cell ?: self.view];
}

/// 统一「下载中」HUD（无按钮 alert，完成后 dismiss，与既有壁纸流程一致）
- (UIAlertController *)presentDownloadHUD {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:nil
                                                                 message:localize(@"bing.download.hint", nil)
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];
    return hud;
}

- (void)applyItem:(BingWallpaperItem *)item {
    if (!item) return;
    UIAlertController *hud = [self presentDownloadHUD];
    __weak typeof(self) weakSelf = self;

    [[BingWallpaperManager sharedManager] ensureImageForItem:item completion:^(NSString *_Nullable path, NSError *_Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [hud dismissViewControllerAnimated:YES completion:^{
            if (!strongSelf) return;
            if (!path) {
                [strongSelf showAlertTitle:nil message:error.localizedDescription ?: localize(@"bing.apply.failed", nil)];
                return;
            }
            [[BackgroundManager sharedManager] setBingBackgroundImageAtPath:path completion:^(BOOL ok, NSError *_Nullable applyError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) {
                        [strongSelf.collectionView reloadData];
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundChanged" object:nil];
                        [strongSelf showAlertTitle:nil message:localize(@"bing.apply.success", nil)];
                    } else {
                        [strongSelf showAlertTitle:nil message:applyError.localizedDescription ?: localize(@"bing.apply.failed", nil)];
                    }
                });
            }];
        }];
    }];
}

- (void)saveItemToPhotos:(BingWallpaperItem *)item {
    if (!item) return;
    UIAlertController *hud = [self presentDownloadHUD];
    __weak typeof(self) weakSelf = self;

    [[BingWallpaperManager sharedManager] ensureImageForItem:item completion:^(NSString *_Nullable path, NSError *_Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!path) {
            [hud dismissViewControllerAnimated:YES completion:^{
                [strongSelf showAlertTitle:nil message:error.localizedDescription ?: localize(@"bing.save.failed", nil)];
            }];
            return;
        }
        [strongSelf saveFileToPhotosAtPath:path hud:hud];
    }];
}

- (void)saveFileToPhotosAtPath:(NSString *)path hud:(UIAlertController *)hud {
    __weak typeof(self) weakSelf = self;

    void (^performSave)(void) = ^{
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (!image) {
            [hud dismissViewControllerAnimated:YES completion:^{
                [weakSelf showAlertTitle:nil message:localize(@"bing.save.failed", nil)];
            }];
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        } completionHandler:^(BOOL success, NSError *_Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [hud dismissViewControllerAnimated:YES completion:^{
                    [weakSelf showAlertTitle:nil message:success ? localize(@"bing.save.success", nil)
                                                                 : (error.localizedDescription ?: localize(@"bing.save.failed", nil))];
                }];
            });
        }];
    };

    // 相册「添加」权限（Info.plist 已含 NSPhotoLibraryAddUsageDescription）
    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                    performSave();
                } else {
                    [hud dismissViewControllerAnimated:YES completion:^{
                        [weakSelf showAlertTitle:nil message:localize(@"bing.save.failed", nil)];
                    }];
                }
            });
        }];
    } else {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (status == PHAuthorizationStatusAuthorized) {
                    performSave();
                } else {
                    [hud dismissViewControllerAnimated:YES completion:^{
                        [weakSelf showAlertTitle:nil message:localize(@"bing.save.failed", nil)];
                    }];
                }
            });
        }];
    }
}

- (void)showAlertTitle:(NSString *_Nullable)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
