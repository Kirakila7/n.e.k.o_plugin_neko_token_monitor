// Explicit click only. TRAE CN: avatar -> quota -> credits. No payment controls.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#include "quota-panel.h"

static double deadline;
static NSString *diagnostic = @"activation";
static id attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static NSString *text(AXUIElementRef element) {
    for (NSString *key in @[@"AXTitle", @"AXDescription", @"AXValue"]) {
        id value = attribute(element, (__bridge CFStringRef)key);
        if ([value isKindOfClass:NSString.class] && [value length] && [value length] <= 256) return value;
    }
    return @"";
}
static NSArray *children(AXUIElementRef element) {
    id value = attribute(element, kAXChildrenAttribute);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
static void collect(AXUIElementRef element, NSMutableArray *nodes, int depth, int *budget) {
    // Breadth first: a shallow modal must not wait behind an entire chat history.
    NSMutableArray *queue=[NSMutableArray arrayWithObject:@{@"element":(__bridge id)element,@"depth":@(depth)}];
    NSUInteger cursor=0;BOOL heading=NO,description=NO;
    while(cursor<queue.count&&--*budget>=0&&CFAbsoluteTimeGetCurrent()<deadline){
        NSDictionary *item=queue[cursor++];int level=[item[@"depth"] intValue];
        AXUIElementRef current=(__bridge AXUIElementRef)item[@"element"];
        if(level>40)continue;
        NSString *role=attribute(current,kAXRoleAttribute);
        if([@[@"AXTextField",@"AXTextArea",@"AXSecureTextField"] containsObject:role]||[attribute(current,CFSTR("AXEditable")) isEqual:@YES])continue;
        NSString *value=text(current);
        [nodes addObject:@{@"element":(__bridge id)current,@"role":role?:@"",@"text":value}];
        if([role isEqual:@"AXHeading"]&&[value isEqual:@"增购积分"])heading=YES;
        if([value isEqual:@"购买额外积分"])description=YES;
        if(heading&&description)return;
        for(id child in children(current)){
            if(queue.count-cursor>(NSUInteger)MAX(0,*budget))break;
            [queue addObject:@{@"element":child,@"depth":@(level+1)}];
        }
    }
}
static BOOL has(NSArray *nodes, NSString *value, NSString *role) {
    for (NSDictionary *node in nodes) if ([node[@"text"] isEqual:value] && (!role || [node[@"role"] isEqual:role])) return YES;
    return NO;
}
static NSArray *buttons(NSArray *nodes, NSString *value) {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *node in nodes) if ([node[@"role"] isEqual:@"AXButton"] && [node[@"text"] isEqual:value]) [matches addObject:node[@"element"]];
    return matches;
}
static NSArray *controls(NSArray *nodes, NSArray *values, NSArray *roles) {
    NSMutableArray *matches=[NSMutableArray array];
    for(NSDictionary *node in nodes)if([values containsObject:node[@"text"]]&&[roles containsObject:node[@"role"]])[matches addObject:node[@"element"]];
    return matches;
}
static BOOL press(NSArray *matches) {
    if (matches.count != 1 || CFAbsoluteTimeGetCurrent() > deadline) return NO;
    AXUIElementRef element = (__bridge AXUIElementRef)matches[0];
    if ([attribute(element, kAXEnabledAttribute) isEqual:@NO]) return NO;
    CFArrayRef actions = NULL;
    if (AXUIElementCopyActionNames(element, &actions) != kAXErrorSuccess) return NO;
    BOOL available = [(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXPressAction];
    CFRelease(actions);
    return available && AXUIElementPerformAction(element, kAXPressAction) == kAXErrorSuccess;
}
static void avatarParts(AXUIElementRef element, int depth, BOOL *image, BOOL *tier) {
    if (depth > 3 || CFAbsoluteTimeGetCurrent() > deadline) return;
    NSString *role = attribute(element, kAXRoleAttribute);
    if ([@[@"AXButton",@"AXTextField",@"AXTextArea",@"AXSecureTextField"] containsObject:role]) return;
    if ([role isEqual:@"AXImage"]) *image = YES;
    if ([@[@"Free",@"Lite",@"Pro",@"Pro+",@"Ultra"] containsObject:text(element)]) *tier = YES;
    for (id child in children(element)) avatarParts((__bridge AXUIElementRef)child,depth+1,image,tier);
}
static NSArray *avatars(NSArray *nodes) {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *node in nodes) {
        if (![node[@"role"] isEqual:@"AXButton"]) continue;
        NSString *label=node[@"text"];
        if([label rangeOfString:@"(?:^|\\s)(?:Free|Lite|Pro\\+?|Ultra)(?:$|\\s)" options:NSRegularExpressionSearch].location==NSNotFound)continue;
        BOOL image = NO, tier = NO;
        for (id child in children((__bridge AXUIElementRef)node[@"element"])) {
            avatarParts((__bridge AXUIElementRef)child,0,&image,&tier);
        }
        if (image && tier) [matches addObject:node[@"element"]];
    }
    return matches;
}
static NSArray *quotaMenuButtons(NSArray *nodes) {
    if ((!has(nodes, @"签到", @"AXButton")&&!has(nodes,@"已签到",@"AXButton")) || !has(nodes, @"管理账户", @"AXButton")) return @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSRegularExpression *number = [NSRegularExpression regularExpressionWithPattern:@"^(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.[0-9]+)?$" options:0 error:nil];
    for (NSDictionary *node in nodes) {
        NSString *value = node[@"text"];
        if ([node[@"role"] isEqual:@"AXButton"] && [number numberOfMatchesInString:value options:0 range:NSMakeRange(0,value.length)] == 1) [matches addObject:node[@"element"]];
    }
    return matches;
}
static int emit(BOOL ok, NSString *error, NSArray *steps) {
    NSDictionary *result = ok ? @{@"ok":@YES, @"stage":@"credits", @"payment_confirmed":@NO, @"steps":steps} :
        @{@"ok":@NO, @"error":error ?: @"not_confirmed", @"payment_confirmed":@NO, @"steps":steps, @"diagnostic":diagnostic};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout); return 0;
}
static BOOL returnToApp(NSArray *nodes) {
    // The official return control is a list item, not an AXButton in TRAE.
    for(NSDictionary *node in nodes)if([node[@"text"]isEqual:@"返回应用"]){
        AXUIElementRef current=(AXUIElementRef)CFRetain((__bridge AXUIElementRef)node[@"element"]);
        for(int level=0;level<3&&current;level++){
            if(press(@[(__bridge id)current])){CFRelease(current);return YES;}
            id parent=attribute(current,kAXParentAttribute);CFRelease(current);
            current=parent?(AXUIElementRef)CFRetain((__bridge AXUIElementRef)parent):NULL;
        }
        if(current)CFRelease(current);
    }
    return NO;
}
static int emitQuota(NSArray *panels,BOOL restored,NSArray *steps) {
    NSDictionary *value=restored?@{@"ok":@YES,@"panels":panels,@"restored":@YES,@"steps":steps}:
        @{@"ok":@NO,@"error":@"restore_failed"};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    NSString *profile=argc==2?[NSString stringWithUTF8String:argv[1]]:@"";
    BOOL quotaRead=[profile isEqual:@"trae-quota"];
    if(quotaRead)profile=@"trae";
    BOOL workbuddy=[profile isEqual:@"workbuddy"];
    if (![profile isEqual:@"trae"]&&!workbuddy) return emit(NO,@"unsupported",@[]);
    if (!AXIsProcessTrusted()) return emit(NO,@"permission",@[]);
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    NSArray *bundles=workbuddy?@[@"com.tencent.workbuddy",@"com.tencent.WorkBuddy",@"com.tencent.codebuddy.workbuddy"]:@[@"cn.trae.app"];
    NSMutableArray *running=[NSMutableArray array];
    for(NSRunningApplication *process in workspace.runningApplications)
        if([bundles containsObject:process.bundleIdentifier]||(workbuddy&&[process.bundleIdentifier hasPrefix:@"com.tencent."]&&[process.localizedName.lowercaseString isEqual:@"workbuddy"]))[running addObject:process];
    NSRunningApplication *app = running.count == 1 ? running[0] : nil;
    if (!app) {
        if(quotaRead)return emit(NO,@"not_running",@[]);
        if (running.count > 1) return emit(NO,@"not_confirmed",@[]);
        NSURL *url=nil;
        for(NSString *bundle in bundles){url=[workspace URLForApplicationWithBundleIdentifier:bundle];if(url)break;}
        if (!url) return emit(NO,@"not_installed",@[]);
        __block BOOL finished = NO;
        __block NSRunningApplication *launched = nil;
        [workspace openApplicationAtURL:url configuration:NSWorkspaceOpenConfiguration.configuration completionHandler:^(NSRunningApplication *opened, NSError *error) {
            launched = opened; finished = YES;
        }];
        double launchDeadline = CFAbsoluteTimeGetCurrent()+2;
        while (!finished && CFAbsoluteTimeGetCurrent() < launchDeadline)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        app = launched;
        if (!app) return emit(NO,@"not_confirmed",@[]);
    }
    if(!quotaRead){
        // Explicit top-up clicks may arrive while another app is foreground.
        // Ask LaunchServices to reopen the existing app instead of relying only
        // on activateWithOptions, which recent macOS releases may defer.
        if(app.bundleURL){
            NSWorkspaceOpenConfiguration *configuration=NSWorkspaceOpenConfiguration.configuration;
            configuration.activates=YES;configuration.createsNewApplicationInstance=NO;
            __block BOOL reopened=NO;
            [workspace openApplicationAtURL:app.bundleURL configuration:configuration completionHandler:^(NSRunningApplication *opened,NSError *error){reopened=YES;}];
            double reopenDeadline=CFAbsoluteTimeGetCurrent()+2;
            while(!reopened&&CFAbsoluteTimeGetCurrent()<reopenDeadline)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        }
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    }
    deadline = CFAbsoluteTimeGetCurrent() + (quotaRead?8:12);
    AXUIElementRef root = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(root, .15);
    NSMutableArray *steps = [NSMutableArray array];
    BOOL avatarPressed = NO, quotaPressed = NO, creditsPressed = NO, activated = NO, settingsPressed=NO;
    NSString *error = @"not_confirmed";
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        pid_t foreground = workspace.frontmostApplication.processIdentifier;
        if(quotaRead&&!activated)activated=YES;
        if (foreground == app.processIdentifier) activated = YES;
        else if (activated&&!quotaRead) { error = @"interrupted"; break; }
        if (activated) {
            NSMutableArray *nodes = [NSMutableArray array]; int budget = 5000;
            collect(root,nodes,0,&budget);
            diagnostic = creditsPressed ? @"no_modal" : quotaPressed ? @"no_credits" : avatarPressed ? @"no_quota" : nodes.count < 5 ? @"no_window" : @"no_avatar";
            if(quotaRead){
                // Never touch an existing purchase dialog or a user's open quota page.
                if(has(nodes,@"购买额外积分",nil)){error=@"interrupted";break;}
                if(has(nodes,@"总可用积分",nil)&&has(nodes,@"返回应用",nil)){
                    NSArray *panels=CFQuotaPanels(root,@[@"总可用积分"]);
                    if(!panels.count){[NSThread sleepForTimeInterval:.12];continue;}
                    BOOL restored=!quotaPressed;
                    if(quotaPressed&&returnToApp(nodes)){
                        double savedDeadline=deadline;deadline=CFAbsoluteTimeGetCurrent()+1.5;
                        while(CFAbsoluteTimeGetCurrent()<deadline){
                            NSMutableArray *after=[NSMutableArray array];int limit=5000;collect(root,after,0,&limit);
                            if(!has(after,@"返回应用",nil)){restored=YES;break;}
                            [NSThread sleepForTimeInterval:.08];
                        }
                        deadline=savedDeadline;
                    }
                    CFRelease(root);return emitQuota(panels,restored,steps);
                }
                if(!quotaPressed&&quotaMenuButtons(nodes).count==1){
                    if(press(quotaMenuButtons(nodes))){quotaPressed=YES;[steps addObject:@"quota"];}else break;
                }else if(!avatarPressed&&!quotaPressed){
                    NSArray *matches=avatars(nodes);
                    if(matches.count==1&&press(matches)){avatarPressed=YES;[steps addObject:@"avatar"];}
                }
                [NSThread sleepForTimeInterval:.12];continue;
            }
            if(workbuddy){
                BOOL purchase=has(nodes,@"购买积分",@"AXHeading")||has(nodes,@"积分加量包",@"AXHeading");
                BOOL payment=has(nodes,@"扫码支付",nil)||has(nodes,@"支付方式",nil)||has(nodes,@"微信支付",nil);
                if(purchase&&payment){CFRelease(root);return emit(YES,nil,steps);}
                BOOL plan=has(nodes,@"套餐与积分",nil)||has(nodes,@"套餐与用量",nil);
                if(!creditsPressed&&plan&&buttons(nodes,@"购买积分").count==1){
                    if(press(buttons(nodes,@"购买积分"))){creditsPressed=YES;[steps addObject:@"credits"];}else break;
                }else if(!quotaPressed&&!creditsPressed){
                    NSArray *matches=controls(nodes,@[@"套餐与积分",@"套餐与用量"],@[@"AXButton",@"AXRadioButton"]);
                    if(matches.count==1&&press(matches)){quotaPressed=YES;[steps addObject:@"quota"];}
                    else if(!settingsPressed){
                        NSArray *settings=controls(nodes,@[@"设置…",@"设置...",@"Settings…",@"Settings..."],@[@"AXMenuItem"]);
                        if(settings.count==1&&press(settings)){settingsPressed=YES;[steps addObject:@"settings"];}
                    }
                }
                [NSThread sleepForTimeInterval:.12];continue;
            }
            // Confirm the modal by two distinct official labels, not the button alone.
            if (has(nodes,@"增购积分",@"AXHeading") && has(nodes,@"购买额外积分",nil)) {
                CFRelease(root); return emit(YES,nil,steps);
            }
            if (!creditsPressed && has(nodes,@"总可用积分",nil) && has(nodes,@"返回应用",nil)) {
                if (press(buttons(nodes,@"增购积分"))) { creditsPressed = YES; [steps addObject:@"credits"]; }
                else break;
            } else if (!quotaPressed && !creditsPressed && quotaMenuButtons(nodes).count == 1) {
                if (press(quotaMenuButtons(nodes))) { quotaPressed = YES; [steps addObject:@"quota"]; }
                else break;
            } else if (!avatarPressed && !quotaPressed && !creditsPressed) {
                NSArray *matches = avatars(nodes);
                if (matches.count == 1) {
                    if (press(matches)) { avatarPressed = YES; [steps addObject:@"avatar"]; }
                    else break;
                }
            }
        }
        [NSThread sleepForTimeInterval:.12];
    }
    if(quotaRead&&quotaPressed){deadline=CFAbsoluteTimeGetCurrent()+1;NSMutableArray *nodes=[NSMutableArray array];int limit=5000;collect(root,nodes,0,&limit);returnToApp(nodes);}
    // Close only a menu we opened; AXCancel never injects Escape into an editor.
    if(quotaRead&&avatarPressed&&!quotaPressed)AXUIElementPerformAction(root,kAXCancelAction);
    CFRelease(root); return emit(NO,error,steps);
} }
