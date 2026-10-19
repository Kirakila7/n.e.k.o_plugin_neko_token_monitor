// Collect only balance-label neighbourhoods, excluding editable fields.
static id CFQuotaAttr(AXUIElementRef e, CFStringRef key) {
    CFTypeRef v=NULL;
    if(AXUIElementCopyAttributeValue(e,key,&v)!=kAXErrorSuccess)return nil;
    return CFBridgingRelease(v);
}
static NSString *CFQuotaLabel(AXUIElementRef e) {
    if([@[@"AXTextField",@"AXTextArea",@"AXSecureTextField"]containsObject:CFQuotaAttr(e,kAXRoleAttribute)])return nil;
    for(NSString *key in @[@"AXValue",@"AXTitle",@"AXDescription"]){
        id v=CFQuotaAttr(e,(__bridge CFStringRef)key);
        if([v isKindOfClass:NSString.class]&&[v length]&&[v length]<=256)return v;
    }
    return nil;
}
static NSArray *CFQuotaChildren(AXUIElementRef e) {
    id v=CFQuotaAttr(e,kAXChildrenAttribute);return [v isKindOfClass:NSArray.class]?v:@[];
}
static void CFQuotaTexts(AXUIElementRef e,NSMutableArray *out,int depth,int *budget) {
    if(depth>8||--*budget<0||out.count>=200)return;
    NSString *v=CFQuotaLabel(e);if(v)[out addObject:v];
    for(id child in CFQuotaChildren(e))CFQuotaTexts((__bridge AXUIElementRef)child,out,depth+1,budget);
}
static void CFQuotaFind(AXUIElementRef e,NSArray *markers,NSMutableArray *out,int depth,int *budget) {
    if(depth>28||--*budget<0||out.count>=100)return;
    NSArray *kids=CFQuotaChildren(e);BOOL found=NO;
    for(id child in kids){
        NSString *v=CFQuotaLabel((__bridge AXUIElementRef)child);
        for(NSString *marker in markers)if([v isEqualToString:marker]||[v hasPrefix:[marker stringByAppendingString:@"："]]||[v hasPrefix:[marker stringByAppendingString:@":"]])found=YES;
    }
    if(found){NSMutableArray *texts=[NSMutableArray array];int limit=600;CFQuotaTexts(e,texts,0,&limit);if(texts.count)[out addObject:texts];return;}
    for(id child in kids)CFQuotaFind((__bridge AXUIElementRef)child,markers,out,depth+1,budget);
}
static NSArray *CFQuotaPanels(AXUIElementRef root,NSArray *markers) {
    NSMutableArray *out=[NSMutableArray array];int budget=4000;CFQuotaFind(root,markers,out,0,&budget);return out;
}
