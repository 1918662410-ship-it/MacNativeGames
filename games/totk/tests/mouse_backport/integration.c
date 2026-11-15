#include "input.c"
#include <assert.h>
static uint64_t now=1000000000;
uint64_t runtime_now_ns(void){return now;}
void runtime_survey_cancel_user(void){}
uint8_t *runtime_module_base(const char *name){(void)name;return NULL;}
void runtime_autoload_user_input(void){}
void runtime_gamepad_read(RuntimeGamepadState *s){*s=(RuntimeGamepadState){0};}
void runtime_gamepad_clear(void){}
uint64_t runtime_gamepad_held_buttons(void){return 0;}
int runtime_handheld_mode(void){return 0;}
void runtime_hid_feedback_stats(uint64_t *a,uint64_t *b){*a=*b=0;}
_Noreturn void runtime_fail(const char *s){fprintf(stderr,"%s\n",s);abort();}
static NpadState readpad(void){NpadState s;uint32_t id=0;full_states(&s,1,&id);return s;}
static void tick(void){now+=10000000;runtime_mouse_tick();}
int main(void){
 initialize();
 assert(escape_button_for_state(BOW_UNKNOWN)==2&&escape_button_for_state(BOW_PAUSED)==2);
 assert(escape_button_for_state(BOW_NOT_DRAWN)==1024&&escape_button_for_state(BOW_DRAWN)==1024);
 runtime_input_key(36,1);assert(readpad().buttons==1);runtime_input_key(36,0);assert(!readpad().buttons);
 runtime_input_key(49,1);assert(readpad().buttons==4);runtime_input_key(49,0);assert(!readpad().buttons);
 runtime_input_key(53,1);assert(readpad().buttons==2);runtime_input_key(53,1);assert(readpad().buttons==2);runtime_input_key(53,0);assert(!readpad().buttons);
 runtime_input_key(35,1);assert(readpad().buttons==1024);runtime_input_key(35,0);assert(!readpad().buttons);
 runtime_input_key(36,1);runtime_input_key(38,1);readpad();runtime_input_key(36,0);assert(readpad().buttons==1);runtime_input_clear();assert(!readpad().buttons);
 runtime_input_key_synthetic(36,1);assert(readpad().buttons==1024);runtime_input_key_synthetic(36,0);
 puts("PASS: Return=A, Space=X, Esc contextual B/Plus, P=Plus, alias coexistence, legacy script ABI");
 runtime_mouse_capture(1);runtime_mouse_move(12,-8);tick();NpadState s=readpad();
 assert(s.rx>0&&s.ry>0);printf("move right/up -> stick %d,%d\n",s.rx,s.ry);
 RuntimeMotionState m;assert(runtime_motion_read(&m,1)==1);assert(m.gyro[0]>0&&m.gyro[2]<0);
 double acc[3]={0,0,-1},g[3]={9,9,9};runtime_motion_feed(acc,g,now);RuntimeMotionState after;runtime_motion_read(&after,1);assert(after.sampling==m.sampling);
 for(int i=0;i<300;i++)tick();s=readpad();assert(!s.rx&&!s.ry);
 runtime_input_key_synthetic(12,1);tick();runtime_mouse_move(10,0);tick();s=readpad();int x=s.rx;for(int i=0;i<100;i++)tick();assert(readpad().rx==x);printf("wheel held for 1 second -> stick %d unchanged\n",x);
 runtime_input_key_synthetic(12,0);tick();assert(!readpad().rx);
 runtime_mouse_button(0,1);assert(readpad().buttons&8);runtime_mouse_button(0,0);assert(!(readpad().buttons&8));
 runtime_mouse_button(1,1);assert(readpad().buttons&512);runtime_mouse_button(0,1);assert(!(readpad().buttons&(512|8)));runtime_mouse_button(0,0);assert(readpad().buttons&512);
 runtime_input_key_synthetic(32,1);runtime_mouse_capture(0);s=readpad();assert(s.buttons&8);assert(!(s.buttons&512));
 runtime_mouse_capture(1);runtime_mouse_button(0,1);runtime_mouse_capture(0);assert(!(readpad().buttons&512));
 runtime_input_clear();s=readpad();assert(!s.buttons&&!s.rx&&!s.ry);
 runtime_mouse_capture(1);runtime_mouse_button(0,1);runtime_mouse_capture(0);assert(!readpad().buttons);
 runtime_mouse_move(20,20);tick();assert(!readpad().rx);
 runtime_motion_feed(acc,g,now);assert(runtime_motion_read(&m,1)==1);assert(m.gyro[0]>1);
 puts("PASS: axes, decay, wheel, bow buttons, keyboard coexistence, release, gyro ownership");
}
