#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <math.h>
#import "host-layout.h"

int main(void){@autoreleasepool{
    NSDictionary *layout=@{@"available":@YES,@"position":@{@"x":@2268,@"y":@761},
        @"viewport":@{@"width":@2560,@"height":@1440},@"scale":@{@"x":@0.0466,@"y":@0.0466}};
    for(NSValue *value in @[[NSValue valueWithRect:NSMakeRect(-2560,-484,2560,1440)],
        [NSValue valueWithRect:NSMakeRect(1920,0,2560,1440)],
        [NSValue valueWithRect:NSMakeRect(0,33,1280,720)]]){
        CGRect frame=value.rectValue;CGPoint p;BOOL hit=NO;
        // A real regression: YUI moved 495 left and 180 down while preferences
        // still reported the old anchor. Search must intersect the moved body.
        CGRect moved=CGRectMake(frame.origin.x+1660*frame.size.width/2560,
            frame.origin.y+710*frame.size.height/1440,150*frame.size.width/2560,280*frame.size.height/1440);
        for(NSUInteger n=0;n<4096&&CatFoodHostSearchPoint(layout,frame,n,&p);n++){
            assert(CGRectContainsPoint(frame,p));
            if(CGRectContainsPoint(moved,p))hit=YES;
        }
        assert(hit);
    }
    CGPoint p;
    assert(!CatFoodHostSearchPoint(layout,CGRectMake(0,0,122,122),0,&p));
    assert(!CatFoodHostSearchPoint(layout,CGRectMake(NAN,0,1920,1080),0,&p));
    assert(!CatFoodHostSearchPoint(layout,CGRectMake(0,0,1920,1080),4096,&p));
    assert(CatFoodHostSearchPoint(nil,CGRectMake(-1920,0,1920,1080),0,&p));
    assert(CatFoodHostSearchPoint(@{@"scale":@3},CGRectMake(0,0,1920,1080),0,&p));
    assert(!CatFoodHostHoverPoint(layout,CGRectMake(0,0,122,122),0,&p));
    assert(CatFoodHostHoverPoint(layout,CGRectMake(-2560,-484,2560,1440),0,&p));
    assert(fabs(p.x+292)<0.001&&fabs(p.y-277)<0.001);
    puts("PASS: moved body, negative display origins, scaled viewport, bounds, malformed layout, return-ball rejection");
}return 0;}
