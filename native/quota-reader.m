// Read-only AX quota-panel collector. No clicks, prompts, credential access or network.
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static id attr(AXUIElementRef e, CFStringRef key) {
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, key, &v) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(v);
}
static NSString *label(AXUIElementRef e) {
    NSString *role = attr(e, kAXRoleAttribute);
    if ([role isEqual:@"AXTextField"] || [role isEqual:@"AXTextArea"] || [role isEqual:@"AXSecureTextField"]) return nil;
    for (NSString *key in @[@"AXValue", @"AXTitle", @"AXDescription"]) {
        id v = attr(e, (__bridge CFStringRef)key);
        if ([v isKindOfClass:NSString.class] && [v length] && [v length] <= 256) return v;
    }
    return nil;
}
static NSArray *children(AXUIElementRef e) {
    id value = attr(e, kAXChildrenAttribute);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
static void smallTexts(AXUIElementRef e, NSMutableArray *out, int depth, int *budget) {
    if (depth > 8 || --*budget < 0 || out.count >= 200) return;
    NSString *v = label(e);
    if (v) [out addObject:v];
    for (id child in children(e)) smallTexts((__bridge AXUIElementRef)child, out, depth + 1, budget);
}
static void findPanels(AXUIElementRef e, NSArray *markers, NSMutableArray *out, int depth, int *budget) {
    if (depth > 28 || --*budget < 0 || out.count >= 100) return;
    NSArray *kids = children(e);
    BOOL found = NO;
    for (id child in kids) {
        NSString *v = label((__bridge AXUIElementRef)child);
        for (NSString *marker in markers) if ([v isEqualToString:marker] || [v hasPrefix:[marker stringByAppendingString:@"："]] || [v hasPrefix:[marker stringByAppendingString:@":"]]) found = YES;
    }
    if (found) {
        NSMutableArray *texts = [NSMutableArray array]; int limit = 600;
        smallTexts(e, texts, 0, &limit);
        if (texts.count) [out addObject:texts];
        return;
    }
    for (id child in kids) findPanels((__bridge AXUIElementRef)child, markers, out, depth + 1, budget);
}
static int emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout); return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    NSString *app = argc == 2 ? [NSString stringWithUTF8String:argv[1]] : @"";
    NSDictionary *targets = @{@"trae": @[@"cn.trae.app", @"com.trae.app"],
                              @"workbuddy": @[@"com.tencent.workbuddy", @"com.tencent.WorkBuddy", @"com.tencent.codebuddy.workbuddy"]};
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
        int budget = 4000;
        findPanels(root, markers, panels, 0, &budget); CFRelease(root);
    }
    if (!running) return emit(@{@"ok":@NO, @"error":@"not_running"});
    return emit(@{@"ok":@YES, @"panels":panels});
} }
