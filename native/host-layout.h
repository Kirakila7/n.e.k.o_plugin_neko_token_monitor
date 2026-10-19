// AX frames use global top-left screen points. Saved anchors use renderer points.
static BOOL CatFoodLayoutNumber(id value, double low, double high) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()
        && isfinite([value doubleValue]) && [value doubleValue]>=low && [value doubleValue]<=high;
}
static BOOL CatFoodHostHoverPoint(NSDictionary *layout, CGRect frame, NSUInteger attempt, CGPoint *point) {
    if(![layout isKindOfClass:NSDictionary.class]||![layout[@"available"]isEqual:@YES]
        ||!isfinite(frame.origin.x)||!isfinite(frame.origin.y)||!isfinite(frame.size.width)||!isfinite(frame.size.height)
        ||frame.size.width<320||frame.size.height<240)return NO;
    id position=layout[@"position"],viewport=layout[@"viewport"],scale=layout[@"scale"];
    if(![position isKindOfClass:NSDictionary.class]||![viewport isKindOfClass:NSDictionary.class]||![scale isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in @[@"x",@"y"])
        if(!CatFoodLayoutNumber(position[key],-100000,100000)||!CatFoodLayoutNumber(scale[key],0.001,10))return NO;
    if(!CatFoodLayoutNumber(viewport[@"width"],100,20000)||!CatFoodLayoutNumber(viewport[@"height"],100,20000))return NO;
    double rx=frame.size.width/[viewport[@"width"]doubleValue],ry=frame.size.height/[viewport[@"height"]doubleValue];
    double size=MIN(4,MAX(0.4,[scale[@"y"]doubleValue]/0.05));
    const CGPoint offsets[]={{0,0},{0,-80},{0,-160},{-60,-80},{60,-80}};
    CGPoint offset=offsets[attempt%5];
    double x=frame.origin.x+([position[@"x"]doubleValue]+offset.x*size)*rx;
    double y=frame.origin.y+([position[@"y"]doubleValue]+offset.y*size)*ry;
    // Do not clamp a stale/off-screen anchor into an unrelated part of the desktop.
    if(x<CGRectGetMinX(frame)||x>=CGRectGetMaxX(frame)||y<CGRectGetMinY(frame)||y>=CGRectGetMaxY(frame))return NO;
    *point=CGPointMake(x,y);return YES;
}

// Saved preferences can lag a drag. Search only this verified NEKO window,
// using hover (never coordinate clicks) until the named goodbye control exists.
// Start with the nearest row/column so ordinary moves do not require a full pass.
static BOOL CatFoodHostSearchPoint(NSDictionary *layout, CGRect frame, NSUInteger attempt, CGPoint *point) {
    if(!isfinite(frame.origin.x)||!isfinite(frame.origin.y)||!isfinite(frame.size.width)||!isfinite(frame.size.height)
        ||frame.size.width<320||frame.size.height<240||frame.size.width>20000||frame.size.height>20000)return NO;
    CGPoint anchor=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
    CatFoodHostHoverPoint(layout,frame,0,&anchor);
    id s=[layout isKindOfClass:NSDictionary.class]?layout[@"scale"]:nil,v=[layout isKindOfClass:NSDictionary.class]?layout[@"viewport"]:nil;
    if(![s isKindOfClass:NSDictionary.class])s=nil;if(![v isKindOfClass:NSDictionary.class])v=nil;
    double scale=CatFoodLayoutNumber(s[@"y"],0.001,10)?[s[@"y"]doubleValue]/0.05:1;
    double rx=CatFoodLayoutNumber(v[@"width"],100,20000)?frame.size.width/[v[@"width"]doubleValue]:1;
    double ry=CatFoodLayoutNumber(v[@"height"],100,20000)?frame.size.height/[v[@"height"]doubleValue]:1;
    double dx=MAX(24,MIN(120,96*scale*rx)),dy=MAX(40,MIN(190,168*scale*ry));
    NSUInteger columns=ceil(frame.size.width/dx),rows=ceil(frame.size.height/dy);
    if(columns*rows>4096||attempt>=columns*rows)return NO;
    // Equal cells include both edges, even when the saved anchor is near a corner.
    double width=frame.size.width/columns,height=frame.size.height/rows;
    NSMutableArray<NSNumber *> *xs=[NSMutableArray new],*ys=[NSMutableArray new];
    for(NSUInteger x=0;x<columns;x++)[xs addObject:@(frame.origin.x+(x+0.5)*width)];
    for(NSUInteger y=0;y<rows;y++)[ys addObject:@(frame.origin.y+(y+0.5)*height)];
    [xs sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b){return [@(fabs(a.doubleValue-anchor.x)) compare:@(fabs(b.doubleValue-anchor.x))];}];
    [ys sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b){return [@(fabs(a.doubleValue-anchor.y)) compare:@(fabs(b.doubleValue-anchor.y))];}];
    *point=CGPointMake(xs[attempt%columns].doubleValue,ys[attempt/columns].doubleValue);return YES;
}
