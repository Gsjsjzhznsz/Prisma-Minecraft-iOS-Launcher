#import "FileListViewController.h"
#import "BackgroundManager.h"

@interface FileListViewController () {
}

@property(nonatomic) NSMutableArray *fileList;

@end

@implementation FileListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // ★ Task230（反馈 #8：文件夹只显示毛玻璃覆盖层和名称，不显示内容）：
    //   旧透明管线（makeViewControllerTransparent：clear 视图 + clear 表格
    //   + 洗白单元格）让列表内容隐形——与 Task229 修的 FolderBrowser 同款
    //   病，但这个遗留的 .json 选择器（自定义控件/偏好配置页在用）漏了。
    //   改为实底（与系统文件 App 同观感）：背景重申不交还透明管线。
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.tableView.backgroundView = nil;
    {
        // 整树豁免全局白底描边字体（实底浅色列表上白字隐形）
        extern void ame230_setViewTreeStrokeExempt(UIView *, BOOL);
        ame230_setViewTreeStrokeExempt(self.view, YES);
    }

    if (self.fileList == nil) {
        self.fileList = [NSMutableArray array];
    } else {
        [self.fileList removeAllObjects];
    }

    // List files
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:self.listPath error:nil];
    for(NSString *file in files) {
        NSString *path = [self.listPath stringByAppendingPathComponent:file];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:(&isDir)];
        if(!isDir && [file hasSuffix:@".json"]) {
            [self.fileList addObject:[file stringByDeletingPathExtension]];
        }
    }

    [self.tableView setSeparatorStyle:UITableViewCellSeparatorStyleSingleLine];

    // 监听背景 UI 效果变化通知，当用户切换背景效果（半透明/毛玻璃）时重新应用透明化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// 背景效果改变时重申实底（不再交还透明管线——旧重铺会把列表洗回隐形）
- (void)reapplyBackgroundEffect {
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"cell"];
    }

    cell.textLabel.text = [self.fileList objectAtIndex:indexPath.row];
    // Task230：实底列表 + 语义色（白底描边字体豁免后的原生观感）
    cell.textLabel.textColor = [UIColor labelColor];
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [self dismissViewControllerAnimated:YES completion:nil];

    self.whenItemSelected(self.fileList [indexPath.row]);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSString *str = [self.fileList objectAtIndex:indexPath.row];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [NSString stringWithFormat:@"%@/%@.json", self.listPath, str];
        if (self.whenDelete != nil) {
            self.whenDelete(path);
        }
        [fm removeItemAtPath:path error:nil];
        [self.fileList removeObjectAtIndex:indexPath.row];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    }
}

@end
