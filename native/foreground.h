// Frontmost host plus allowlisted wallet fields. No inputs or URL paths.
static id CFFrontAttribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value=NULL;
    if(AXUIElementCopyAttributeValue(element,key,&value)!=kAXErrorSuccess)return nil;
    return CFBridgingRelease(value);
}
static NSString *CFFrontHostAt(AXUIElementRef element) {
    for(NSString *key in @[@"AXURL",@"AXDocument"]){
        id raw=CFFrontAttribute(element,(__bridge CFStringRef)key);
        NSURL *url=[raw isKindOfClass:NSURL.class]?raw:[raw isKindOfClass:NSString.class]&&[raw length]<8192?[NSURL URLWithString:raw]:nil;
        if([@[@"https",@"http"]containsObject:url.scheme.lowercaseString]&&url.host.length<=253)return url.host.lowercaseString;
    }
    return nil;
}
static NSString *CFFrontPageHost(AXUIElementRef root) {
    // Prefer the focused pane (including a browser embedded beside a chat).
    id focused=CFFrontAttribute(root,kAXFocusedUIElementAttribute);
    for(NSUInteger n=0;focused&&n<20;n++){
        NSString *host=CFFrontHostAt((__bridge AXUIElementRef)focused);if(host.length)return host;
        NSString *role=CFFrontAttribute((__bridge AXUIElementRef)focused,kAXRoleAttribute);
        if([role isEqual:@"AXWindow"])break;
        focused=CFFrontAttribute((__bridge AXUIElementRef)focused,kAXParentAttribute);
    }
    id window=CFFrontAttribute(root,kAXFocusedWindowAttribute);
    if(!window)window=CFFrontAttribute(root,kAXMainWindowAttribute);
    if(!window)return nil;
    NSMutableArray *queue=[NSMutableArray arrayWithObject:@{@"node":window,@"depth":@0}];
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+0.35;
    for(NSUInteger i=0;i<queue.count&&i<100&&CFAbsoluteTimeGetCurrent()<deadline;i++){
        NSDictionary *item=queue[i];AXUIElementRef node=(__bridge AXUIElementRef)item[@"node"];
        NSString *host=CFFrontHostAt(node);if(host.length)return host;
        NSString *role=CFFrontAttribute(node,kAXRoleAttribute);
        if([@[@"AXTextField",@"AXTextArea",@"AXSecureTextField"]containsObject:role]||[item[@"depth"]integerValue]>=10)continue;
        id children=CFFrontAttribute(node,kAXChildrenAttribute);
        if([children isKindOfClass:NSArray.class])for(id child in children){
            if(queue.count>=100)break;
            [queue addObject:@{@"node":child,@"depth":@([item[@"depth"]integerValue]+1)}];
        }
    }
    return nil;
}
static NSArray *CFFrontWalletPanels(AXUIElementRef root) {
    id window=CFFrontAttribute(root,kAXFocusedWindowAttribute);
    if(!window)window=CFFrontAttribute(root,kAXMainWindowAttribute);if(!window)return @[];
    NSArray *panels=CFQuotaPanels((__bridge AXUIElementRef)window,@[@"充值余额",@"赠送余额"]);
    NSMutableArray *out=[NSMutableArray array];
    NSRegularExpression *money=[NSRegularExpression regularExpressionWithPattern:@"^(?:[¥￥]|CNY|RMB|[¥￥]?\\s*[0-9,]+(?:\\.[0-9]+)?(?:\\s*(?:CNY|RMB))?)$" options:NSRegularExpressionCaseInsensitive error:nil];
    for(NSArray *panel in panels){
        NSMutableArray *fields=[NSMutableArray array];
        for(NSString *raw in panel){
            NSString *text=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if([text isEqual:@"充值余额"]||[text isEqual:@"赠送余额"])[fields addObject:text];
            else if([text hasSuffix:@"赠送余额"])[fields addObject:@"赠送余额"];
            else if([text hasPrefix:@"累计消费金额"])[fields addObject:@"累计消费金额"];
            else if(text.length<=128&&[money numberOfMatchesInString:text options:0 range:NSMakeRange(0,text.length)]==1)[fields addObject:text];
            if(fields.count>=24)break;
        }
        if(fields.count)[out addObject:fields];if(out.count>=4)break;
    }
    return out;
}
static NSDictionary *CFFrontContext(void) {
    NSRunningApplication *app=NSWorkspace.sharedWorkspace.frontmostApplication;
    NSString *bundle=app.bundleIdentifier?:@"";
    NSMutableDictionary *value=[@{@"bundle":bundle} mutableCopy];
    NSSet *webApps=[NSSet setWithArray:@[@"com.google.Chrome",@"com.google.Chrome.canary",@"com.google.chrome.for.testing",@"com.apple.Safari",@"com.microsoft.edgemac",@"com.brave.Browser",@"company.thebrowser.Browser",@"com.openai.codex",@"com.openai.chat",@"com.anthropic.claudefordesktop"]];
    if([webApps containsObject:bundle]){
        if(AXIsProcessTrusted()){
            AXUIElementRef root=AXUIElementCreateApplication(app.processIdentifier);
            AXUIElementSetMessagingTimeout(root,0.08);
            NSString *host=CFFrontPageHost(root);
            if([host isEqual:@"platform.deepseek.com"])value[@"wallet_panels"]=CFFrontWalletPanels(root);
            CFRelease(root);
            if(host)value[@"host"]=host;
        }else value[@"error"]=@"permission";
    }
    return value;
}
static void CFWatchForeground(void) {
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    __block NSDictionary *last=nil;__block CFAbsoluteTime lastSent=0;
    void (^sample)(void)=^{
        @autoreleasepool{
            NSDictionary *value=CFFrontContext();CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
            if([last isEqual:value]&&(![value[@"wallet_panels"]count]||now-lastSent<5))return;last=value;lastSent=now;
            NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
        }
    };
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *notification){sample();}];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){sample();}];
    sample();[NSApp run];
}
