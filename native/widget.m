#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <signal.h>
#include <math.h>
#import "host-layout.h"
static volatile sig_atomic_t stopping=0;
static void stopWidget(int signalNumber){stopping=1;}

@interface InputPanel : NSPanel
@end
@implementation InputPanel
- (BOOL)canBecomeKeyWindow{return YES;}
@end

@protocol CatGrabDelegate <NSObject>
- (void)catGrabPhase:(NSString *)phase point:(NSPoint)point;
@end
@interface CatGrabView : NSImageView
@property(weak) id<CatGrabDelegate> grabDelegate;
@property BOOL facingRight;
@end
@implementation CatGrabView
- (BOOL)isOpaque{return NO;}
- (BOOL)acceptsFirstMouse:(NSEvent *)event{return YES;}
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)mouseDownCanMoveWindow{return NO;}
- (void)drawRect:(NSRect)dirtyRect{
    [NSGraphicsContext saveGraphicsState];
    if(self.facingRight){NSAffineTransform *t=[NSAffineTransform transform];[t translateXBy:self.bounds.size.width yBy:0];[t scaleXBy:-1 yBy:1];[t concat];}
    [super drawRect:dirtyRect];[NSGraphicsContext restoreGraphicsState];
}
- (void)resetCursorRects{[self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];}
- (void)mouseDown:(NSEvent *)event{[self.window makeFirstResponder:self];[NSCursor.closedHandCursor set];[self.grabDelegate catGrabPhase:@"start" point:[self.window convertPointToScreen:event.locationInWindow]];}
- (void)mouseDragged:(NSEvent *)event{[self.grabDelegate catGrabPhase:@"move" point:[self.window convertPointToScreen:event.locationInWindow]];}
- (void)mouseUp:(NSEvent *)event{[NSCursor.openHandCursor set];[self.grabDelegate catGrabPhase:@"end" point:[self.window convertPointToScreen:event.locationInWindow]];}
- (void)keyDown:(NSEvent *)event{if(event.keyCode==53)[self.grabDelegate catGrabPhase:@"cancel" point:NSEvent.mouseLocation];else[super keyDown:event];}
@end
static BOOL CatFoodRect(id value,NSRect *rect){
    if(![value isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in @[@"x",@"y",@"width",@"height"])if(![value[key]isKindOfClass:NSNumber.class]||!isfinite([value[key]doubleValue]))return NO;
    *rect=NSMakeRect([value[@"x"]doubleValue],[value[@"y"]doubleValue],[value[@"width"]doubleValue],[value[@"height"]doubleValue]);
    return rect->size.width>0&&rect->size.height>0&&rect->size.width<10000&&rect->size.height<10000;
}

@interface WidgetDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, CatGrabDelegate>
@property NSPanel *panel;
@property WKWebView *web;
@property NSPoint dragMouse;
@property NSPoint dragOrigin;
@property BOOL dragging;
@property NSString *base;
@property pid_t parent;
@property NSMutableDictionary<NSNumber *, NSRunningApplication *> *hiddenApps;
@property NSMutableDictionary<NSNumber *, NSRunningApplication *> *minimizedApps;
@property BOOL recording;
@property NSMutableDictionary<NSNumber *, NSRunningApplication *> *pausedApps;
@property NSMutableSet<NSNumber *> *confirmedPausedApps;
@property BOOL accessibilityPrompted;
@property NSInteger hideAttempts;
@property NSMutableSet<NSNumber *> *accessibilityHiddenApps;
@property BOOL movedPointer;
@property CGPoint savedPointer;
@property CGPoint lastHoverPoint;
@property NSMutableDictionary<NSNumber *, NSNumber *> *pauseAttemptTimes;
@property NSMutableDictionary<NSNumber *, NSNumber *> *pauseAttemptCounts;
@property BOOL retryScheduled;
@property NSInteger takeoverGeneration;
@property CFAbsoluteTime takeoverStarted;
@property BOOL takeoverReported;
@property NSDictionary *hostLayout;
@property BOOL hostLayoutLoading;
@property CFAbsoluteTime hostLayoutRequestedAt;
@property NSMutableDictionary<NSNumber *, NSNumber *> *hostHoverAttempts;
@property NSMutableDictionary<NSNumber *, NSNumber *> *pauseVisibleSince;
@property BOOL restoring;
@property BOOL terminationPending;
@property CFAbsoluteTime restoreStarted;
@property NSMutableDictionary<NSNumber *, NSNumber *> *restoreAttemptTimes;
@property NSMutableDictionary<NSNumber *, NSNumber *> *restoreConfirmations;
@property NSString *sessionId;
@property NSString *recordingDirectory;
@property BOOL isolatedPreview;
@property NSInteger serverPort;
@property NSPanel *chasePanel;
@property WKWebView *chaseWeb;
@property BOOL chaseWanted;
@property CFAbsoluteTime chaseLease;
@property NSPanel *catGrabPanel;
@property BOOL catHeld;
@property NSDictionary *chaseHome;
@property NSInteger chaseCatchTotal;
@property NSImage *catWalkImage;
@property NSImage *catReactImage;
@end
@implementation WidgetDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.isolatedPreview=[NSProcessInfo.processInfo.arguments containsObject:@"--isolated-preview"]||[NSBundle.mainBundle.bundleIdentifier isEqualToString:@"local.neko.catfood.chase-isolated"]||[NSBundle.mainBundle.bundleIdentifier hasPrefix:@"local.neko.catfood.isolated."];
    self.serverPort=self.isolatedPreview?48924:48923;
    id previewPort=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CatfoodPreviewPort"];
    if(self.isolatedPreview&&[previewPort isKindOfClass:NSNumber.class]&&[previewPort integerValue]>1024&&[previewPort integerValue]<65536)self.serverPort=[previewPort integerValue];
    self.base=[NSString stringWithFormat:@"http://127.0.0.1:%ld",(long)self.serverPort];
    self.parent=getppid();
    NSArray *arguments=NSProcessInfo.processInfo.arguments;
    NSUInteger directoryFlag=[arguments indexOfObject:@"--recording-dir"];
    if(directoryFlag!=NSNotFound&&directoryFlag+1<arguments.count&&[arguments[directoryFlag+1] isAbsolutePath])self.recordingDirectory=arguments[directoryFlag+1];
    self.hiddenApps=[NSMutableDictionary new];
    self.minimizedApps=[NSMutableDictionary new];
    self.pausedApps=[NSMutableDictionary new];
    self.confirmedPausedApps=[NSMutableSet new];
    self.accessibilityHiddenApps=[NSMutableSet new];
    self.pauseVisibleSince=[NSMutableDictionary new];
    self.restoreAttemptTimes=[NSMutableDictionary new];
    self.restoreConfirmations=[NSMutableDictionary new];
    self.pauseAttemptTimes=[NSMutableDictionary new];
    self.pauseAttemptCounts=[NSMutableDictionary new];
    self.hostHoverAttempts=[NSMutableDictionary new];
    signal(SIGTERM,stopWidget);
    self.panel=[[InputPanel alloc] initWithContentRect:NSMakeRect(0,0,400,self.isolatedPreview?560:404) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.panel.title=self.isolatedPreview?@"猫粮隔离测试":@"猫粮";
    self.panel.opaque=NO;self.panel.backgroundColor=NSColor.clearColor;self.panel.hasShadow=NO;
    self.panel.level=NSFloatingWindowLevel;self.panel.hidesOnDeactivate=NO;
    self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSRect screen=NSScreen.mainScreen.visibleFrame;
    [self.panel setFrameOrigin:NSMakePoint(NSMaxX(screen)-420,NSMinY(screen)+20)];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    [config.userContentController addScriptMessageHandler:self name:@"nekoWidget"];
    self.web=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,400,404) configuration:config];
    self.web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    [self.web setValue:@NO forKey:@"drawsBackground"];
    self.web.navigationDelegate=self;
    self.panel.contentView=self.web;
    [self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[self.base stringByAppendingString:@"/widget"]]]];
    [self.panel orderFrontRegardless];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){
        if((stopping||(!self.isolatedPreview&&(getppid()!=self.parent||kill(self.parent,0)!=0)))&&!self.terminationPending)[NSApp terminate:nil];
        else if(!self.isolatedPreview&&self.recording&&!self.retryScheduled)[self hideOriginal];
        if(self.chaseWanted&&CFAbsoluteTimeGetCurrent()-self.chaseLease>5)[self stopChase];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
        if(self.chasePanel)[self.chasePanel setFrame:(self.panel.screen?:NSScreen.mainScreen).visibleFrame display:YES];
    }];
}
- (void)reportChase:(BOOL)active {
    NSMutableDictionary *result=[@{@"active":@(active)} mutableCopy];if(self.sessionId)result[@"session_id"]=self.sessionId;
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    NSString *json=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.catfoodNativeChaseState&&window.catfoodNativeChaseState(%@)",json] completionHandler:nil];
}
- (void)stopChase {
    BOOL wasActive=self.chaseWanted||self.chasePanel!=nil;self.chaseWanted=NO;
    if(self.catHeld)[NSCursor.arrowCursor set];self.catHeld=NO;
    [self.catGrabPanel orderOut:nil];self.catGrabPanel.contentView=nil;self.catGrabPanel=nil;
    [self.chasePanel orderOut:nil];[self.chaseWeb stopLoading];self.chasePanel.contentView=nil;self.chaseWeb=nil;self.chasePanel=nil;
    if(wasActive)[self reportChase:NO];
}
- (void)startChase {
    if(!self.recording||!self.takeoverReported){[self reportChase:NO];return;}
    self.chaseLease=CFAbsoluteTimeGetCurrent();
    if(self.chaseWanted)return;self.chaseWanted=YES;
    NSRect area=(self.panel.screen?:NSScreen.mainScreen).visibleFrame;
    self.chasePanel=[[InputPanel alloc] initWithContentRect:area styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    self.chasePanel.title=@"猫粮追逐动画层";self.chasePanel.opaque=NO;self.chasePanel.backgroundColor=NSColor.clearColor;self.chasePanel.hasShadow=NO;
    self.chasePanel.level=NSFloatingWindowLevel-1;self.chasePanel.hidesOnDeactivate=NO;self.chasePanel.ignoresMouseEvents=YES;
    self.chasePanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];[config.userContentController addScriptMessageHandler:self name:@"nekoWidget"];
    self.chaseWeb=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,area.size.width,area.size.height) configuration:config];
    self.chaseWeb.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;[self.chaseWeb setValue:@NO forKey:@"drawsBackground"];self.chaseWeb.navigationDelegate=self;
    self.chasePanel.contentView=self.chaseWeb;
    [self.chaseWeb loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[self.base stringByAppendingString:@"/chase"]]]];
    [self.chasePanel orderFrontRegardless];
}
- (void)updateChaseConfiguration:(id)body {
    if(![body isKindOfClass:NSDictionary.class])return;
    NSRect home;if(CatFoodRect(body[@"home"],&home))self.chaseHome=body[@"home"];
    id total=body[@"catches"];if([total isKindOfClass:NSNumber.class]&&[total doubleValue]>=0&&[total doubleValue]<1e12)self.chaseCatchTotal=[total integerValue];
}
- (void)sendChaseConfiguration {
    if(!self.chaseWeb||!self.chaseHome)return;
    NSRect local;if(!CatFoodRect(self.chaseHome,&local))return;
    NSRect owner=self.panel.frame,area=self.chasePanel.frame;
    NSDictionary *home=@{@"x":@(owner.origin.x+local.origin.x-area.origin.x),@"y":@(NSMaxY(area)-NSMaxY(owner)+local.origin.y),@"width":@(local.size.width),@"height":@(local.size.height)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"home":home,@"catches":@(self.chaseCatchTotal)} options:0 error:nil];
    NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    [self.chaseWeb evaluateJavaScript:[NSString stringWithFormat:@"window.catfoodChaseSetup&&window.catfoodChaseSetup(%@)",json] completionHandler:nil];
}
- (void)updateCatGrabRect:(id)value {
    if(!self.chaseWanted||self.catHeld||!self.chasePanel)return;
    NSRect r;if(!CatFoodRect(value,&r))return;NSRect area=self.chasePanel.frame;
    if(r.origin.x < -r.size.width||r.origin.y < -r.size.height||r.origin.x>area.size.width||r.origin.y>area.size.height)return;
    if(!self.catGrabPanel){
        if(!self.catWalkImage)self.catWalkImage=[[NSImage alloc]initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"cat-walk" withExtension:@"gif"]];
        if(!self.catReactImage)self.catReactImage=[[NSImage alloc]initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"cat-react" withExtension:@"gif"]];
        if(!self.catWalkImage||!self.catReactImage)return;
        self.catGrabPanel=[[InputPanel alloc]initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        self.catGrabPanel.title=@"抱小白猫回家";self.catGrabPanel.opaque=NO;self.catGrabPanel.backgroundColor=NSColor.clearColor;self.catGrabPanel.hasShadow=NO;
        self.catGrabPanel.movableByWindowBackground=NO;self.catGrabPanel.movable=NO;
        self.catGrabPanel.level=NSFloatingWindowLevel-1;self.catGrabPanel.hidesOnDeactivate=NO;
        self.catGrabPanel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        CatGrabView *view=[[CatGrabView alloc]initWithFrame:NSZeroRect];view.grabDelegate=self;view.animates=YES;view.imageScaling=NSImageScaleProportionallyUpOrDown;
        [view setAccessibilityElement:YES];[view setAccessibilityRole:NSAccessibilityImageRole];[view setAccessibilityLabel:@"拖动小白猫回到原站位"];[view setAccessibilityHelp:@"按住奔跑中的小猫，拖到心形落点后松开。"];self.catGrabPanel.contentView=view;
    }
    CatGrabView *view=(CatGrabView *)self.catGrabPanel.contentView;
    BOOL yui=[value[@"form"]isEqualToString:@"yui"];
    BOOL renderInWeb=[value[@"renderInWeb"]boolValue];
    BOOL handoff=view.image==nil&&!yui&&!renderInWeb;
    // WebKit draws both sprites at display cadence; this transparent panel only catches drags.
    NSImage *image=(yui||renderInWeb)?nil:([value[@"reacting"]boolValue]?self.catReactImage:self.catWalkImage);if(view.image!=image)view.image=image;
    self.catGrabPanel.title=yui?@"抱 YUI 回家":@"抱小白猫回家";
    [view setAccessibilityLabel:yui?@"拖动 Q版 YUI 回到原站位":@"拖动小白猫回到原站位"];
    BOOL right=[value[@"facing"]integerValue]>0;if(view.facingRight!=right){view.facingRight=right;view.needsDisplay=YES;}
    [self.catGrabPanel setFrame:NSMakeRect(area.origin.x+r.origin.x,NSMaxY(area)-r.origin.y-r.size.height,r.size.width,r.size.height) display:YES];
    if(!self.catGrabPanel.visible)[self.catGrabPanel orderFrontRegardless];
    if(handoff)[self.chaseWeb evaluateJavaScript:@"window.catfoodChaseNativeCat&&window.catfoodChaseNativeCat()" completionHandler:nil];
}
- (void)catGrabPhase:(NSString *)phase point:(NSPoint)point {
    if(!self.chaseWanted||!self.chaseWeb)return;
    [self.catGrabPanel.contentView setAccessibilityValue:[phase isEqualToString:@"start"]?@"已抱起":[phase isEqualToString:@"move"]?@"抱回中":@"已松开"];
    if([phase isEqualToString:@"start"]){self.catHeld=YES;((CatGrabView *)self.catGrabPanel.contentView).image=nil;}
    NSRect area=self.chasePanel.frame;
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"phase":phase,@"x":@(point.x-area.origin.x),@"y":@(NSMaxY(area)-point.y)} options:0 error:nil];
    NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    [self.chaseWeb evaluateJavaScript:[NSString stringWithFormat:@"window.catfoodChaseDrag&&window.catfoodChaseDrag(%@)",json] completionHandler:nil];
    if(![phase isEqualToString:@"start"]&&![phase isEqualToString:@"move"])self.catHeld=NO;
}
- (BOOL)isNeko:(NSRunningApplication *)app {
    if(app.processIdentifier==getpid())return NO;
    NSString *name=[[app.localizedName lowercaseString] stringByReplacingOccurrencesOfString:@"." withString:@""];
    return [app.bundleIdentifier isEqualToString:@"cn.nekotech.neko"]||[name isEqualToString:@"neko"]||[name isEqualToString:@"neko desktop"];
}
- (BOOL)setAccessibilityHidden:(BOOL)hidden app:(NSRunningApplication *)app {
    // Never prompt or grant permissions here; the user must explicitly enable access in macOS.
    if(!AXIsProcessTrusted())return NO;
    AXUIElementRef target=AXUIElementCreateApplication(app.processIdentifier);
    Boolean settable=false;
    AXError check=AXUIElementIsAttributeSettable(target,kAXHiddenAttribute,&settable);
    AXError result=(check==kAXErrorSuccess&&settable)?AXUIElementSetAttributeValue(target,kAXHiddenAttribute,hidden?kCFBooleanTrue:kCFBooleanFalse):kAXErrorAttributeUnsupported;
    CFTypeRef actual=NULL;
    BOOL confirmed=result==kAXErrorSuccess&&AXUIElementCopyAttributeValue(target,kAXHiddenAttribute,&actual)==kAXErrorSuccess&&CFGetTypeID(actual)==CFBooleanGetTypeID()&&CFBooleanGetValue(actual)==hidden;
    if(hidden&&result==kAXErrorSuccess)[self.accessibilityHiddenApps addObject:@(app.processIdentifier)];
    NSLog(@"CatFood AX hidden=%d settable=%d check=%d result=%d confirmed=%d",hidden,settable,check,result,confirmed);
    if(actual)CFRelease(actual);CFRelease(target);
    return confirmed;
}
// Use NEKO's own goodbye/return controls so its renderer snapshots geometry and pauses.
- (AXUIElementRef)findControl:(NSString *)label root:(AXUIElementRef)root depth:(NSUInteger)depth {
    if(depth>24)return NULL;
    for(NSString *attribute in @[(__bridge NSString *)kAXDescriptionAttribute,(__bridge NSString *)kAXTitleAttribute,(__bridge NSString *)kAXHelpAttribute]){
        CFTypeRef value=NULL;
        if(AXUIElementCopyAttributeValue(root,(__bridge CFStringRef)attribute,&value)==kAXErrorSuccess&&value){
            BOOL matches=CFGetTypeID(value)==CFStringGetTypeID()&&[(__bridge NSString *)value isEqualToString:label];
            CFRelease(value);if(matches)return (AXUIElementRef)CFRetain(root);
        }
    }
    CFTypeRef children=NULL;
    if(AXUIElementCopyAttributeValue(root,kAXChildrenAttribute,&children)!=kAXErrorSuccess||!children)return NULL;
    AXUIElementRef found=NULL;
    if(CFGetTypeID(children)==CFArrayGetTypeID())for(id child in (__bridge NSArray *)children){
        found=[self findControl:label root:(__bridge AXUIElementRef)child depth:depth+1];if(found)break;
    }
    CFRelease(children);return found;
}
- (AXUIElementRef)mainHostWindow:(AXUIElementRef)root {
    CFTypeRef windows=NULL;
    if(AXUIElementCopyAttributeValue(root,kAXWindowsAttribute,&windows)!=kAXErrorSuccess||!windows)return (AXUIElementRef)CFRetain(root);
    AXUIElementRef chosen=NULL;
    if(CFGetTypeID(windows)==CFArrayGetTypeID())for(id candidate in (__bridge NSArray *)windows){
        CFTypeRef title=NULL;
        AXUIElementCopyAttributeValue((__bridge AXUIElementRef)candidate,kAXTitleAttribute,&title);
        BOOL main=title&&CFGetTypeID(title)==CFStringGetTypeID()&&[(__bridge NSString *)title isEqualToString:@"Project N.E.K.O."];
        if(title)CFRelease(title);
        if(main){chosen=(AXUIElementRef)CFRetain((__bridge AXUIElementRef)candidate);break;}
    }
    CFRelease(windows);
    return chosen?:((AXUIElementRef)CFRetain(root));
}
- (BOOL)setHostWindowMinimized:(BOOL)minimized app:(NSRunningApplication *)app {
    AXUIElementRef root=AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementRef host=[self mainHostWindow:root];
    Boolean settable=false;
    AXError check=AXUIElementIsAttributeSettable(host,kAXMinimizedAttribute,&settable);
    AXError result=(check==kAXErrorSuccess&&settable)?AXUIElementSetAttributeValue(host,kAXMinimizedAttribute,minimized?kCFBooleanTrue:kCFBooleanFalse):kAXErrorAttributeUnsupported;
    // Electron acknowledges AX writes before its window state changes. Keep
    // ownership of every accepted minimize, including delayed completions.
    if(minimized&&result==kAXErrorSuccess)self.minimizedApps[@(app.processIdentifier)]=app;
    CFTypeRef actual=NULL;
    BOOL confirmed=result==kAXErrorSuccess&&AXUIElementCopyAttributeValue(host,kAXMinimizedAttribute,&actual)==kAXErrorSuccess&&actual&&CFGetTypeID(actual)==CFBooleanGetTypeID()&&CFBooleanGetValue(actual)==minimized;
    NSLog(@"CatFood window minimized=%d settable=%d check=%d result=%d confirmed=%d",minimized,settable,check,result,confirmed);
    if(actual)CFRelease(actual);CFRelease(host);CFRelease(root);
    return confirmed;
}
- (BOOL)isHostHidden:(NSRunningApplication *)app {
    if(app.hidden)return YES;
    AXUIElementRef root=AXUIElementCreateApplication(app.processIdentifier);
    CFTypeRef hidden=NULL;
    BOOL result=AXUIElementCopyAttributeValue(root,kAXHiddenAttribute,&hidden)==kAXErrorSuccess&&hidden&&CFGetTypeID(hidden)==CFBooleanGetTypeID()&&CFBooleanGetValue(hidden);
    if(hidden)CFRelease(hidden);
    if(!result){
        AXUIElementRef window=[self mainHostWindow:root];
        CFTypeRef minimized=NULL;
        result=AXUIElementCopyAttributeValue(window,kAXMinimizedAttribute,&minimized)==kAXErrorSuccess&&minimized&&CFGetTypeID(minimized)==CFBooleanGetTypeID()&&CFBooleanGetValue(minimized);
        if(minimized)CFRelease(minimized);CFRelease(window);
    }
    CFRelease(root);return result;
}
- (void)restorePointer {
    self.panel.ignoresMouseEvents=NO;
    if(!self.movedPointer)return;
    CGEventRef current=CGEventCreate(NULL);
    CGPoint point=current?CGEventGetLocation(current):CGPointZero;
    if(current)CFRelease(current);
    if(hypot(point.x-self.lastHoverPoint.x,point.y-self.lastHoverPoint.y)<24){
        CGEventRef move=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,self.savedPointer,kCGMouseButtonLeft);
        if(move){CGEventPost(kCGHIDEventTap,move);CFRelease(move);}
    }
    self.movedPointer=NO;
}
- (void)refreshHostLayout {
    if(self.hostLayoutLoading||CFAbsoluteTimeGetCurrent()-self.hostLayoutRequestedAt<1.0)return;
    self.hostLayoutLoading=YES;self.hostLayoutRequestedAt=CFAbsoluteTimeGetCurrent();
    NSInteger generation=self.takeoverGeneration;
    NSURLRequest *request=[NSURLRequest requestWithURL:[NSURL URLWithString:[self.base stringByAppendingString:@"/api/host-layout"]]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.5];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        id value=(!error&&data.length<16384)?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        dispatch_async(dispatch_get_main_queue(),^{
            if(generation!=self.takeoverGeneration)return;
            self.hostLayoutLoading=NO;
            self.hostLayout=[value isKindOfClass:NSDictionary.class]&&[value[@"available"]isEqual:@YES]?value:nil;
        });
    }] resume];
}
- (BOOL)revealHostControls:(AXUIElementRef)host app:(NSRunningApplication *)app {
    if(!self.hostLayout)[self refreshHostLayout];
    CFTypeRef position=NULL,size=NULL;
    AXUIElementCopyAttributeValue(host,kAXPositionAttribute,&position);
    AXUIElementCopyAttributeValue(host,kAXSizeAttribute,&size);
    CGPoint p=CGPointZero,target;CGSize z=CGSizeZero;
    BOOL valid=position&&size&&CFGetTypeID(position)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()
        &&AXValueGetValue(position,kAXValueCGPointType,&p)&&AXValueGetValue(size,kAXValueCGSizeType,&z);
    if(position)CFRelease(position);if(size)CFRelease(size);
    NSNumber *pid=@(app.processIdentifier);NSUInteger attempt=self.hostHoverAttempts[pid].unsignedIntegerValue;
    BOOL saved=valid&&attempt<5&&CatFoodHostHoverPoint(self.hostLayout,(CGRect){p,z},attempt,&target);
    if(!valid||(!saved&&!CatFoodHostSearchPoint(self.hostLayout,(CGRect){p,z},attempt>=5?attempt-5:attempt,&target)))return NO;
    self.hostHoverAttempts[pid]=@(attempt+1);
    if(!self.movedPointer){
        CGEventRef current=CGEventCreate(NULL);
        if(current){self.savedPointer=CGEventGetLocation(current);CFRelease(current);self.movedPointer=YES;}
    }
    self.panel.ignoresMouseEvents=YES;[app activateWithOptions:0];
    for(CGFloat shift=-2;shift<=0;shift+=2){
        CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,CGPointMake(target.x+shift,target.y),kCGMouseButtonLeft);
        if(event){CGEventPost(kCGHIDEventTap,event);CFRelease(event);}
    }
    self.lastHoverPoint=target;
    NSLog(@"CatFood %@ hover pid=%d frame=(%.0f,%.0f %.0fx%.0f) at=(%.0f,%.0f)",saved?@"saved-layout":@"window-search",app.processIdentifier,p.x,p.y,z.width,z.height,target.x,target.y);
    return YES;
}
- (BOOL)hostControl:(NSString *)label app:(NSRunningApplication *)app press:(BOOL)press {
    if(!AXIsProcessTrusted()||![self isNeko:app]||app.terminated)return NO;
    AXUIElementRef root=AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(root,0.5);
    AXUIElementRef host=[self mainHostWindow:root];
    AXUIElementRef control=[self findControl:label root:host depth:0];
    BOOL result=control!=NULL;
    if(control&&press){
        AXError status=AXUIElementPerformAction(control,kAXPressAction);
        if(status!=kAXErrorSuccess){
            CFTypeRef parent=NULL;
            if(AXUIElementCopyAttributeValue(control,kAXParentAttribute,&parent)==kAXErrorSuccess&&parent){
                status=AXUIElementPerformAction((AXUIElementRef)parent,kAXPressAction);CFRelease(parent);
            }
        }
        NSLog(@"CatFood host control %@ status=%d",label,status);result=status==kAXErrorSuccess;
    }
    if(control)CFRelease(control);CFRelease(host);CFRelease(root);return result;
}
- (BOOL)pauseOriginal:(NSRunningApplication *)app {
    NSNumber *pid=@(app.processIdentifier);
    if([self hostControl:@"请她回来" app:app press:NO]){
        if(!self.pauseVisibleSince[pid])self.pauseVisibleSince[pid]=@(CFAbsoluteTimeGetCurrent());
        return CFAbsoluteTimeGetCurrent()-self.pauseVisibleSince[pid].doubleValue>=1.2;
    }
    [self.pauseVisibleSince removeObjectForKey:pid];
    // AXPress can be accepted while NEKO ignores the click during another transition.
    // Retry only the goodbye control, never a toggle or a visible return control.
    CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    if(self.pauseAttemptTimes[pid]&&now-self.pauseAttemptTimes[pid].doubleValue<1.0)return NO;
    if(self.pauseAttemptCounts[pid].integerValue>=4)return NO;
    if([self hostControl:@"请她离开" app:app press:YES]){
        self.pausedApps[pid]=app;
        self.pauseAttemptTimes[pid]=@(now);
        self.pauseAttemptCounts[pid]=@(self.pauseAttemptCounts[pid].integerValue+1);
        return [self hostControl:@"请她回来" app:app press:NO];
    }
    AXUIElementRef root=AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementRef host=[self mainHostWindow:root];
    AXUIElementPerformAction(host,kAXRaiseAction);[self revealHostControls:host app:app];
    CFRelease(host);CFRelease(root);
    return NO;
}
- (void)hideOriginal {
    if(!self.recording)return;
    if(!self.takeoverStarted)self.takeoverStarted=CFAbsoluteTimeGetCurrent();
    NSUInteger found=0;BOOL ok=YES;NSString *reason=@"host_not_found";
    for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications){
        if(![self isNeko:app]||app.terminated)continue;
        found++;
        NSNumber *pid=@(app.processIdentifier);
        if(self.hiddenApps[pid]&&[self.confirmedPausedApps containsObject:pid]&&[self isHostHidden:app])continue;
        if(![self pauseOriginal:app]){ok=NO;reason=@"pause_unconfirmed";continue;}
        [self.confirmedPausedApps addObject:pid];
        if(!app.hidden){
            self.hiddenApps[@(app.processIdentifier)]=app;
            BOOL accepted=[app hide];
            NSLog(@"CatFood hide pid=%d accepted=%d hidden=%d",app.processIdentifier,accepted,app.hidden);
            accepted=accepted&&app.hidden;
            if(!accepted){
                if(!AXIsProcessTrusted()&&!self.accessibilityPrompted){
                    self.accessibilityPrompted=YES;
                    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
                }
                accepted=[self setAccessibilityHidden:YES app:app];
                if(accepted)[self.accessibilityHiddenApps addObject:@(app.processIdentifier)];
                else if([self setHostWindowMinimized:YES app:app])self.minimizedApps[pid]=app;
                else if(![self isHostHidden:app]){ok=NO;reason=@"hide_unconfirmed";}
            }
        }
    }
    if((!ok||found==0)&&CFAbsoluteTimeGetCurrent()-self.takeoverStarted<32.0){
        if(self.retryScheduled)return;
        self.retryScheduled=YES;NSInteger generation=self.takeoverGeneration;
        BOOL searching=self.hostHoverAttempts.allValues.count&&[[self.hostHoverAttempts.allValues valueForKeyPath:@"@max.self"]integerValue]>=5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((searching?0.08:0.35)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(!self.recording||generation!=self.takeoverGeneration)return;
            self.retryScheduled=NO;[self hideOriginal];
        });
        return;
    }
    BOOL confirmed=found>0&&ok;
    if(confirmed)self.takeoverStarted=0;
    [self restorePointer];
    if(confirmed&&self.takeoverReported)return;
    NSLog(@"CatFood takeover result targets=%lu ok=%d reason=%@",(unsigned long)found,confirmed,confirmed?@"confirmed":reason);
    self.takeoverReported=confirmed;
    [self reportNativeState:confirmed reason:confirmed?nil:reason];
}
- (void)reportNativeState:(BOOL)ok reason:(NSString *)reason {
    NSMutableDictionary *state=[@{@"active":@YES,@"ok":@(ok),@"paused":@(ok)} mutableCopy];
    if(self.sessionId)state[@"session_id"]=self.sessionId;
    if(reason)state[@"reason"]=reason;
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    NSString *json=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.catfoodNativeState && window.catfoodNativeState(%@)",json] completionHandler:nil];
}
- (void)restoreOriginal {
    [self persistRecordingEnd];
    [self stopChase];
    self.recording=NO;
    if(self.restoring)return;
    self.takeoverGeneration++;self.retryScheduled=NO;self.takeoverStarted=0;self.takeoverReported=NO;
    if(self.isolatedPreview)return;
    self.restoring=YES;self.restoreStarted=CFAbsoluteTimeGetCurrent();
    [self restorePointer];
    [self.restoreAttemptTimes removeAllObjects];[self.restoreConfirmations removeAllObjects];
    [self.hostHoverAttempts removeAllObjects];
    for(NSRunningApplication *app in self.hiddenApps.allValues)if(!app.terminated){
        [app unhide];
        if([self.accessibilityHiddenApps containsObject:@(app.processIdentifier)])[self setAccessibilityHidden:NO app:app];
        if(self.minimizedApps[@(app.processIdentifier)])[self setHostWindowMinimized:NO app:app];
        NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];
        configuration.activates=YES;configuration.createsNewApplicationInstance=NO;
        if(app.bundleURL)[NSWorkspace.sharedWorkspace openApplicationAtURL:app.bundleURL configuration:configuration completionHandler:nil];
    }
    [self restoreStep];
}
- (void)restoreStep {
    if(!self.restoring)return;
    NSMutableDictionary *targets=[self.hiddenApps mutableCopy];[targets addEntriesFromDictionary:self.pausedApps];
    BOOL all=YES;CFAbsoluteTime now=CFAbsoluteTimeGetCurrent();
    for(NSNumber *pid in targets){
        NSRunningApplication *app=targets[pid];if(app.terminated)continue;
        if(self.restoreConfirmations[pid].integerValue>=2)continue;
        BOOL hidden=[self isHostHidden:app];
        if(hidden){
            [app unhide];
            if([self.accessibilityHiddenApps containsObject:pid])[self setAccessibilityHidden:NO app:app];
            if(self.minimizedApps[pid])[self setHostWindowMinimized:NO app:app];
        }
        AXUIElementRef root=AXUIElementCreateApplication(app.processIdentifier);
        AXUIElementSetMessagingTimeout(root,0.5);
        AXUIElementRef host=[self mainHostWindow:root];
        AXUIElementPerformAction(host,kAXRaiseAction);
        BOOL returned=[self hostControl:@"请她回来" app:app press:NO];
        BOOL model=!self.pausedApps[pid]||(!returned&&[self hostControl:@"请她离开" app:app press:NO]);
        if(!hidden&&model)self.restoreConfirmations[pid]=@(self.restoreConfirmations[pid].integerValue+1);
        else{
            self.restoreConfirmations[pid]=@0;
            if(!hidden&&returned&&now-self.restoreAttemptTimes[pid].doubleValue>=1.5){
                [self hostControl:@"请她回来" app:app press:YES];self.restoreAttemptTimes[pid]=@(now);
            }else if(!hidden&&!returned)[self revealHostControls:host app:app];
        }
        CFRelease(host);CFRelease(root);
        if(self.restoreConfirmations[pid].integerValue<2)all=NO;
    }
    if(!all&&now-self.restoreStarted<24){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self restoreStep];});return;
    }
    for(NSNumber *pid in targets)NSLog(@"CatFood restore pid=%@ window_confirmed=%d model_confirmed=%d",pid,![self isHostHidden:targets[pid]],self.restoreConfirmations[pid].integerValue>=2);
    NSLog(@"CatFood restore result ok=%d seconds=%.3f",all,now-self.restoreStarted);
    [self restorePointer];
    [self.minimizedApps removeAllObjects];[self.accessibilityHiddenApps removeAllObjects];[self.hiddenApps removeAllObjects];
    [self.pausedApps removeAllObjects];
    [self.confirmedPausedApps removeAllObjects];
    [self.pauseAttemptTimes removeAllObjects];[self.pauseAttemptCounts removeAllObjects];
    [self.pauseVisibleSince removeAllObjects];
    [self.hostHoverAttempts removeAllObjects];self.hostLayout=nil;self.hostLayoutLoading=NO;self.hostLayoutRequestedAt=0;
    self.restoring=NO;
    if(self.terminationPending){self.terminationPending=NO;[NSApp replyToApplicationShouldTerminate:YES];}
}
- (void)persistRecordingEnd {
    if(!self.recordingDirectory||!self.sessionId||![[NSUUID alloc]initWithUUIDString:self.sessionId])return;
    NSString *name=[NSString stringWithFormat:@"closed-%@.json",self.sessionId.lowercaseString];
    NSString *path=[self.recordingDirectory stringByAppendingPathComponent:name];
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"session_id":self.sessionId.lowercaseString} options:0 error:nil];
    NSError *error=nil;
    if(![data writeToFile:path options:NSDataWritingAtomic error:&error])NSLog(@"CatFood could not persist session end: %@",error.localizedDescription);
    else [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
}
- (void)mainWebFailed {
    // The UI cannot send recordEnd after a renderer crash. Restore before quitting;
    // the durable marker lets Python close the session without any HTTP request.
    [self restoreOriginal];
    [self.panel orderOut:nil];
    [NSApp terminate:nil];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if(!self.isolatedPreview&&(self.restoring||self.hiddenApps.count||self.pausedApps.count)){
        [self restoreOriginal];
        if(self.restoring){self.terminationPending=YES;return NSTerminateLater;}
        return NSTerminateNow;
    }
    [self persistRecordingEnd];[self stopChase];return NSTerminateNow;
}
- (void)applicationWillTerminate:(NSNotification *)notification {[self persistRecordingEnd];[self stopChase];}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if(!message.frameInfo.isMainFrame||![message.frameInfo.securityOrigin.host isEqualToString:@"127.0.0.1"]||message.frameInfo.securityOrigin.port!=self.serverPort)return;
    NSString *action=nil,*session=nil;
    if([message.body isKindOfClass:NSString.class])action=message.body;
    else if([message.body isKindOfClass:NSDictionary.class]){
        id value=message.body[@"action"],identifier=message.body[@"session_id"];
        if([value isKindOfClass:NSString.class])action=value;
        if([identifier isKindOfClass:NSString.class]&&[identifier length]<=100)session=identifier;
    }
    if(!action)return;
    if(message.webView==self.chaseWeb){
        if([action isEqualToString:@"chaseReady"]&&self.chaseWanted){[self sendChaseConfiguration];[self reportChase:YES];}
        else if([action isEqualToString:@"chaseAssetError"])[self stopChase];
        else if([action isEqualToString:@"chaseGeometry"])[self updateCatGrabRect:message.body[@"rect"]];
        else if([action isEqualToString:@"chaseEvent"]&&self.chaseWanted){
            id kind=message.body[@"kind"],identifier=message.body[@"event_id"];
            if([@[@"start",@"reverse",@"counter_tag",@"flee",@"stop",@"pause",@"resume"]containsObject:kind]&&[identifier isKindOfClass:NSString.class]&&[identifier length]>0&&[identifier length]<=100){
                NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"kind":kind,@"event_id":identifier} options:0 error:nil];NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
                [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.catfoodGameEvent&&window.catfoodGameEvent(%@)",json] completionHandler:nil];
            }
        }
        else if([action isEqualToString:@"chaseCaught"]&&self.chaseWanted){
            id identifier=message.body[@"event_id"];
            if([identifier isKindOfClass:NSString.class]&&[identifier length]>0&&[identifier length]<=100){
                NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"event_id":identifier} options:0 error:nil];NSString *json=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
                [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.catfoodGameCatch&&window.catfoodGameCatch(%@)",json] completionHandler:nil];
            }
        }else if([action isEqualToString:@"catReturned"]&&self.chaseWanted)[self.web evaluateJavaScript:@"window.catfoodGameReturned&&window.catfoodGameReturned()" completionHandler:nil];
        return;
    }
    if(message.webView!=self.web)return;
    if([action hasPrefix:@"chase"]){
        if(session&&self.sessionId&&![session isEqualToString:self.sessionId])return;
        [self updateChaseConfiguration:message.body];
        if([action isEqualToString:@"chaseStart"])[self startChase];
        else if([action isEqualToString:@"chaseStop"])[self stopChase];
        else if([action isEqualToString:@"chaseHeartbeat"]&&self.chaseWanted){self.chaseLease=CFAbsoluteTimeGetCurrent();[self sendChaseConfiguration];}
        else if([action isEqualToString:@"chaseConfigure"])[self sendChaseConfiguration];
        else if([action isEqualToString:@"chaseInspect"]&&self.isolatedPreview&&self.chaseWeb){
            [self.chaseWeb evaluateJavaScript:@"window.catfoodChaseInspect&&window.catfoodChaseInspect()" completionHandler:^(id result,NSError *error){
                NSRect h;if(!self.catGrabPanel||!CatFoodRect(self.chaseHome,&h))return;
                NSRect owner=self.panel.frame,grab=self.catGrabPanel.frame;
                double x=owner.origin.x+h.origin.x+h.size.width/2-grab.origin.x;
                double y=NSMaxY(grab)-(NSMaxY(owner)-h.origin.y-h.size.height/2);
                [self.catGrabPanel.contentView setAccessibilityHelp:[NSString stringWithFormat:@"隔离拖拽验证：原站位相对本窗口 x=%.1f y=%.1f；输入层 %.1f x %.1f",x,y,grab.size.width,grab.size.height]];
                [self.catGrabPanel makeKeyAndOrderFront:nil];[self.catGrabPanel makeFirstResponder:self.catGrabPanel.contentView];
            }];
        }
        return;
    }
    if([action isEqualToString:@"settings"])[NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:self.base]];
    else if([action isEqualToString:@"recordStart"]){
        if(self.restoring){[self reportNativeState:NO reason:@"restore_in_progress"];return;}
        // Status polling and initial page load can both request the same session.
        // Retrying a completed takeover would activate and unhide NEKO again.
        if(self.recording&&(!session||[session isEqualToString:self.sessionId]))return;
        if(self.recording){[self restoreOriginal];return;}
        self.sessionId=session;self.takeoverGeneration++;
        self.hostLayout=nil;self.hostLayoutLoading=NO;self.hostLayoutRequestedAt=0;[self.hostHoverAttempts removeAllObjects];
        self.takeoverStarted=0;self.takeoverReported=NO;
        if(self.isolatedPreview){self.recording=YES;self.takeoverReported=YES;[self reportNativeState:YES reason:nil];return;}
        if(!AXIsProcessTrusted()){
            if(!self.accessibilityPrompted){
                self.accessibilityPrompted=YES;
                AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
            }
            NSLog(@"CatFood cannot take over: Accessibility permission is unavailable");
            [self reportNativeState:NO reason:@"accessibility"];
        }else{self.recording=YES;self.hideAttempts=0;[self hideOriginal];}
    }
    else if([action isEqualToString:@"recordEnd"]){if(!session||!self.sessionId||[session isEqualToString:self.sessionId])[self restoreOriginal];}
    else if([action isEqualToString:@"hide"])[NSApp terminate:nil];
    else if([action isEqualToString:@"dragStart"]){self.dragging=YES;self.dragMouse=NSEvent.mouseLocation;self.dragOrigin=self.panel.frame.origin;}
    else if([action isEqualToString:@"dragEnd"])self.dragging=NO;
    else if([action isEqualToString:@"dragMove"]&&self.dragging){NSPoint p=NSEvent.mouseLocation;[self.panel setFrameOrigin:NSMakePoint(self.dragOrigin.x+p.x-self.dragMouse.x,self.dragOrigin.y+p.y-self.dragMouse.y)];}
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *url=action.request.URL;
    handler(([url.host isEqualToString:@"127.0.0.1"]&&url.port.integerValue==self.serverPort&&[url.scheme isEqualToString:@"http"])?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if(webView==self.web)[webView evaluateJavaScript:@"window.catfoodChaseCapabilities={desktop:true};window.dispatchEvent(new Event('catfood:chasecapabilities'))" completionHandler:nil];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {if(webView==self.web)[self mainWebFailed];else if(webView==self.chaseWeb)[self stopChase];}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {if(error.code==NSURLErrorCancelled)return;if(webView==self.web)[self mainWebFailed];else if(webView==self.chaseWeb)[self stopChase];}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self webView:webView didFailNavigation:navigation withError:error];}
@end
int main(int argc,const char *argv[]){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];WidgetDelegate *delegate=[WidgetDelegate new];app.delegate=delegate;[app run];}return 0;}
