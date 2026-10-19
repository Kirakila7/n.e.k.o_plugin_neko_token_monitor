// Read-only AX quota-panel collector. No clicks, prompts, credential access or network.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

#include "quota-panel.h"
#include "foreground.h"

static int emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout); return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    NSString *app = argc == 2 ? [NSString stringWithUTF8String:argv[1]] : @"";
    if([app isEqual:@"foreground-watch"]){CFWatchForeground();return 0;}
    if([app isEqual:@"foreground"])return emit(CFFrontContext());
    NSDictionary *targets = @{@"trae": @[@"cn.trae.app", @"com.trae.app"],
                              @"workbuddy": @[@"com.tencent.workbuddy", @"com.tencent.WorkBuddy", @"com.tencent.codebuddy.workbuddy"]};
    if ([app isEqual:@"trae-watch"]) {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSWorkspace *workspace=NSWorkspace.sharedWorkspace;
        void (^notify)(NSString *,NSRunningApplication *)=^(NSString *event,NSRunningApplication *process){
            if(![@[@"cn.trae.app",@"com.trae.app"]containsObject:process.bundleIdentifier])return;
            NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"event":event,@"pid":@(process.processIdentifier)} options:0 error:nil];
            fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
        };
        NSMutableSet *known=[NSMutableSet set];
        for(NSRunningApplication *process in workspace.runningApplications){
            if([targets[@"trae"]containsObject:process.bundleIdentifier])[known addObject:@(process.processIdentifier)];
            notify(@"running",process);
        }
        NSNotificationCenter *center=workspace.notificationCenter;
        for(NSString *name in @[NSWorkspaceDidLaunchApplicationNotification,NSWorkspaceDidActivateApplicationNotification]){
            [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *notification){
                notify([name isEqual:NSWorkspaceDidLaunchApplicationNotification]?@"launch":@"activate",notification.userInfo[NSWorkspaceApplicationKey]);
            }];
        }
        // LaunchServices notifications can be delayed for a command-line helper.
        // A cheap in-process fallback detects actual process/focus changes too.
        __block pid_t lastFront=workspace.frontmostApplication.processIdentifier;
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){
            NSMutableSet *current=[NSMutableSet set];
            for(NSRunningApplication *process in workspace.runningApplications){
                if(![targets[@"trae"]containsObject:process.bundleIdentifier])continue;
                NSNumber *pid=@(process.processIdentifier);[current addObject:pid];
                if(![known containsObject:pid])notify(@"launch",process);
            }
            [known setSet:current];
            NSRunningApplication *front=workspace.frontmostApplication;
            if(front.processIdentifier!=lastFront){lastFront=front.processIdentifier;notify(@"activate",front);}
        }];
        [NSApp run];return 0;
    }
    if (!targets[app]) return emit(@{@"ok":@NO, @"error":@"unsupported"});
    if (!AXIsProcessTrusted()) return emit(@{@"ok":@NO, @"error":@"permission"});
    NSMutableArray *panels = [NSMutableArray array]; BOOL running = NO;
    for (NSRunningApplication *process in NSWorkspace.sharedWorkspace.runningApplications) {
        BOOL matches = [targets[app] containsObject:process.bundleIdentifier];
        // WorkBuddy variants must both carry Tencent's bundle prefix and its exact app name.
        if ([app isEqual:@"workbuddy"] && [process.bundleIdentifier hasPrefix:@"com.tencent."] && [process.localizedName.lowercaseString isEqual:@"workbuddy"]) matches = YES;
        if (!matches) continue;
        running = YES;
        AXUIElementRef root = AXUIElementCreateApplication(process.processIdentifier);
        AXUIElementSetMessagingTimeout(root, .2);
        NSArray *markers = [app isEqual:@"trae"] ? @[@"总可用积分"] : @[@"剩余积分", @"可用积分", @"积分余额", @"总可用积分", @"Credits remaining", @"Available credits"];
        [panels addObjectsFromArray:CFQuotaPanels(root,markers)]; CFRelease(root);
    }
    if (!running) return emit(@{@"ok":@NO, @"error":@"not_running"});
    return emit(@{@"ok":@YES, @"panels":panels});
} }
