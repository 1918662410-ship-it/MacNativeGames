#import "frontend.m"
#include <assert.h>
#undef assert
#define assert(x) do {if(!(x)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x);front_mouse_capture(NO);exit(1);}}while(0)
static int captured,moves,buttons;
void runtime_mouse_capture(int on){captured=on;}
void runtime_mouse_move(double x,double y){if(x||y)moves++;}
void runtime_mouse_button(unsigned b,int down){if(b<3)buttons+=down?1:-1;}
void runtime_input_key(unsigned c,int down){(void)c;(void)down;}
void runtime_input_clear(void){}
void runtime_oe_push_message(uint32_t x){(void)x;}
int main(void){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[NSApp finishLaunching];
 window=[[TOTKGameWindow alloc]initWithContentRect:NSMakeRect(100,100,400,200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 window.title=@"鼠标捕获自动测试（无游戏存档）";window.contentView=[[TOTKInputView alloc]initWithFrame:NSMakeRect(0,0,400,200)];
 [window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 for(int i=0;i<40;i++)[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
 [window makeKeyWindow];assert(window.isKeyWindow);TOTKInputView *v=(TOTKInputView *)window.contentView;
 NSEvent *click=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(50,50) modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
 [v mouseDown:click];assert(mouseHeld&&captured&&buttons==0);
 [v mouseDown:click];assert(buttons==1);[v mouseUp:click];assert(!buttons);
 NSEvent *key=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"7" charactersIgnoringModifiers:@"7" isARepeat:NO keyCode:26];
 [v keyDown:key];assert(!mouseHeld&&!captured);[v keyDown:key];assert(mouseHeld&&captured);
 TOTKWindowDelegate *d=[TOTKWindowDelegate new];[d windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];assert(!mouseHeld&&!captured);
 textEntryOpen=YES;front_mouse_capture(YES);assert(!mouseHeld);textEntryOpen=NO;
 front_mouse_capture(YES);assert(mouseHeld);front_mouse_capture(NO);assert(!mouseHeld);
 puts("PASS: real macOS capture, first click consumed, buttons, key 7, focus loss, text-entry release");
 [window orderOut:nil];
}}
