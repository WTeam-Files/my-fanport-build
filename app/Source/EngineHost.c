#include "HostInternal.h"
#include "wasm-rt-impl.h"
#include <pthread.h>
#include "NativeEngineConfiguration.h"
#include "NativeControllerLook.h"
#include "NativeTouchContext.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <sys/mman.h>
#include <TargetConditionals.h>
#include <os/proc.h>
#include <mach/mach.h>
#include "NativeMemoryBudget.h"

static struct w2c_env env;
static struct w2c_wasi__snapshot__preview1 wasi = { .env = &env };
static PGLogCallback logCallback;
static void *logContext;
static char *manifestPath;
static char missingImport[256];
static _Atomic uint64_t inputBlock;
static int configuredWidth=960,configuredHeight=540,configuredFrameLimit=2;
// Start mode for the engine's loading-screen choice (WasmInputBlock.startMode):
// 1 Story Mode, 2 Sandbox Mode on the GTA V map. Read by f569 (game_36.c).
static int configuredStartMode=2;
static _Atomic uint64_t audioRing;
static _Atomic uint32_t audioCapacity;
static _Atomic bool started;
static bool benchmarkEnabled(void) { const char *value=getenv("PG_BENCHMARK");return value&&atoi(value)!=0; }
void pg_record_memory_fault(unsigned long long address,unsigned long long bytes,unsigned long long limit) {
 char line[240];snprintf(line,sizeof line,"Native heap access fault: address 0x%llx, bytes %llu, memory limit %llu",address,bytes,limit);pg_log(line);
}

void pg_log(const char *message) {
  fprintf(stderr, "[native-port] %s\n", message);
  if (logCallback) logCallback(message, logContext);
}

void pg_missing_import(const char *name) {
  snprintf(missingImport, sizeof(missingImport), "%s", name);
  char message[384];
  snprintf(message, sizeof(message), "Engine stopped at unported host function: %s", name);
  pg_log(message);
  wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}

void *pg_pointer(struct w2c_env *host, uint64_t address, uint64_t size) {
  wasm_rt_shared_memory_t *memory=w2c_env_memory(host);
  if (address > memory->size || size > memory->size - address)
    wasm_rt_trap(WASM_RT_TRAP_OOB);
  return (uint8_t *)(void *)memory->data + address;
}

const char *pg_string(struct w2c_env *host, uint64_t address) {
  const char *s = pg_pointer(host, address, 1);
  if (!memchr(s, 0, w2c_env_memory(host)->size - address)) wasm_rt_trap(WASM_RT_TRAP_OOB);
  return s;
}

wasm_rt_shared_memory_t *w2c_env_memory(struct w2c_env *host) { return &env.memory; }
static double timeMS(clockid_t clock) {
  struct timespec time;
  clock_gettime(clock, &time);
  return time.tv_sec * 1000.0 + time.tv_nsec / 1000000.0;
}
f64 w2c_env_emscripten_get_now(struct w2c_env *host) { return timeMS(CLOCK_MONOTONIC); }
f64 w2c_env_wasm_now_ms(struct w2c_env *host) { return timeMS(CLOCK_REALTIME); }
f64 w2c_env_emscripten_date_now(struct w2c_env *host) { return timeMS(CLOCK_REALTIME); }
u64 w2c_env_emscripten_get_heap_max(struct w2c_env *host) { wasm_rt_shared_memory_t *memory=w2c_env_memory(host);return memory->max_pages*memory->page_size; }
static bool nativeMemoryGuard;
static _Atomic uint64_t memoryBudgetClamps,memoryBudgetQueries;
uint64_t PGMemoryBudgetQueries(void){return atomic_load(&memoryBudgetQueries);}
uint64_t PGMemoryBudgetClamps(void){return atomic_load(&memoryBudgetClamps);}
static uint64_t simulatedProcessLimit;
static bool nativeProcessHeadroom(uint64_t *headroom){
 if(!nativeMemoryGuard)return false;
 atomic_fetch_add(&memoryBudgetQueries,1);
 uint64_t available;
#if TARGET_OS_SIMULATOR
 // Simulator has no iOS Jetsam ceiling. Use an explicit simulated process limit.
 if(!simulatedProcessLimit)return false;
 task_vm_info_data_t info={};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)!=KERN_SUCCESS)return false;
 available=simulatedProcessLimit>info.phys_footprint?simulatedProcessLimit-info.phys_footprint:0;
#else
 available=os_proc_available_memory();
#endif
 *headroom=available;
 return true;
}
uint64_t pg_streaming_available_memory(uint64_t engineAvailable){
 uint64_t available;
 if(!nativeProcessHeadroom(&available))return engineAvailable;
 uint64_t result=pg_streaming_headroom_budget(engineAvailable,available,384ull*1048576);
 if(result<engineAvailable)atomic_fetch_add(&memoryBudgetClamps,1);
 return result;
}
uint64_t pg_streaming_resource_memory(uint64_t engineAvailable){
 uint64_t available;
 if(!nativeProcessHeadroom(&available))return engineAvailable;
 int64_t result=pg_streaming_resource_budget((int64_t)engineAvailable,available,384ull*1048576);
 if(result<(int64_t)engineAvailable)atomic_fetch_add(&memoryBudgetClamps,1);
 return (uint64_t)result;
}
static u32 nativeEngineCores=2;
u32 w2c_env_emscripten_num_logical_cores(struct w2c_env *host) { return nativeEngineCores; }
void w2c_env_emscripten_check_blocking_allowed(struct w2c_env *host) {}
void w2c_env_wasm_print_line_js(struct w2c_env *host, u64 address) { pg_log(pg_string(host, address)); }
void w2c_env_wasm_hang_line_js(struct w2c_env *host, u64 address) { pg_log(pg_string(host, address)); }
u32 w2c_env_wasm_has_page_js(struct w2c_env *host) { return 1; }
u32 w2c_env_wasm_userdata_page_js(struct w2c_env *host) { return 0; }
u32 w2c_env_wasm_module_int_js(struct w2c_env *host, u64 address, u32 fallback) {
  const char *key = pg_string(host, address);
  if (!strcmp(key, "lowMemory")) return 1;
  return fallback;
}
void w2c_env_0x5Femscripten_init_main_thread_js(struct w2c_env *host, u64 thread) {
  w2c_game_0x5Femscripten_thread_init(&host->game, thread, 0, 1, 1, 1048576, 0);
  w2c_game_0x5Femscripten_tls_init(&host->game);
}
void w2c_env_0x5Femscripten_thread_mailbox_await(struct w2c_env *host, u64 thread) {
  // The initial probe runs on a native blocking thread with no JS event loop.
}
void w2c_env_0x5Femscripten_thread_set_strongref(struct w2c_env *host, u64 thread) {}

static void writeTM(struct w2c_env *host, uint64_t at, const struct tm *time) {
  int32_t *out = pg_pointer(host, at, 48);
  out[0] = time->tm_sec; out[1] = time->tm_min; out[2] = time->tm_hour;
  out[3] = time->tm_mday; out[4] = time->tm_mon; out[5] = time->tm_year;
  out[6] = time->tm_wday; out[7] = time->tm_yday; out[8] = time->tm_isdst;
  *(int64_t *)((uint8_t *)out + 40) = time->tm_gmtoff;
}
u32 w2c_env_0x5Fgmtime_js(struct w2c_env *host, u64 seconds, u64 at) {
  time_t value = (int64_t)seconds;
  struct tm time;
  if (!gmtime_r(&value, &time)) return 1;
  writeTM(host, at, &time);
  return 0;
}
u32 w2c_env_0x5Flocaltime_js(struct w2c_env *host, u64 seconds, u64 at) {
  time_t value = (int64_t)seconds;
  struct tm time;
  if (!localtime_r(&value, &time)) return 1;
  writeTM(host, at, &time);
  return 0;
}
u64 w2c_env_0x5Fmktime_js(struct w2c_env *host, u64 at) {
  int32_t *in = pg_pointer(host, at, 36);
  struct tm time = {0};
  time.tm_sec = in[0]; time.tm_min = in[1]; time.tm_hour = in[2];
  time.tm_mday = in[3]; time.tm_mon = in[4]; time.tm_year = in[5];
  time.tm_isdst = in[8];
  time_t result = mktime(&time);
  if (result != -1) writeTM(host, at, &time);
  return (u64)result;
}
void w2c_env_0x5Ftzset_js(struct w2c_env *host, u64 zone, u64 daylight, u64 standardName, u64 daylightName) {
  tzset();
  time_t now = time(NULL);
  struct tm current, january = {0}, july = {0};
  localtime_r(&now, &current);
  january.tm_year = july.tm_year = current.tm_year;
  january.tm_mday = july.tm_mday = 1;
  january.tm_isdst = july.tm_isdst = -1;
  july.tm_mon = 6;
  mktime(&january); mktime(&july);
  const struct tm *standard = january.tm_gmtoff <= july.tm_gmtoff ? &january : &july;
  const struct tm *summer = standard == &january ? &july : &january;
  *(int64_t *)pg_pointer(host, zone, 8) = -standard->tm_gmtoff;
  *(int32_t *)pg_pointer(host, daylight, 4) = january.tm_gmtoff != july.tm_gmtoff;
  char *stdName = pg_pointer(host, standardName, 17);
  char *dstName = pg_pointer(host, daylightName, 17);
  snprintf(stdName, 17, "%s", standard->tm_zone ? standard->tm_zone : "UTC");
  snprintf(dstName, 17, "%s", summer->tm_zone ? summer->tm_zone : "UTC");
}

u32 w2c_env_wasm_httpfs_manifest_js(struct w2c_env *host, u64 address, u32 capacity) {
  FILE *file = fopen(manifestPath, "rb");
  if (!file) return (u32)-1;
  fseek(file, 0, SEEK_END);
  long length = ftell(file);
  rewind(file);
  if (length < 0 || length >= UINT32_MAX) { fclose(file); return (u32)-1; }
  if (capacity > (uint32_t)length) {
    char *output = pg_pointer(host, address, length + 1);
    if (fread(output, 1, length, file) != (size_t)length) { fclose(file); return (u32)-1; }
    output[length] = 0;
  }
  fclose(file);
  return (u32)length;
}

u32 w2c_env_emscripten_asm_const_int(struct w2c_env *host, u64 code, u64 sig, u64 arguments) {
  if (code == 7980558) {
    // Emscripten's language query is the only boot-time embedded JS expression.
    u64 destinationAddress = *(u64 *)pg_pointer(host, arguments, 8);
    u32 capacity = *(u32 *)pg_pointer(host, arguments + 8, 4);
    const char *language = "en-US";
    if (capacity) {
      char *destination = pg_pointer(host, destinationAddress, capacity);
      snprintf(destination, capacity, "%s", language);
    }
    return 0;
  }
  pg_missing_import("emscripten_asm_const_int: non-language expression");
  return 0;
}
u32 w2c_env_emscripten_asm_const_int_sync_on_main_thread(struct w2c_env *host, u64 code, u64 sig, u64 args) {
  return w2c_env_emscripten_asm_const_int(host, code, sig, args);
}

u32 w2c_wasi__snapshot__preview1_clock_time_get(struct w2c_wasi__snapshot__preview1 *host, u32 clock, u64 precision, u64 output) {
  if (clock > 3) return 28;
  struct timespec t;
  clock_gettime(clock == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &t);
  *(u64 *)pg_pointer(host->env, output, 8) = (u64)t.tv_sec * 1000000000 + t.tv_nsec;
  return 0;
}
u32 w2c_wasi__snapshot__preview1_environ_sizes_get(struct w2c_wasi__snapshot__preview1 *host, u64 count, u64 size) {
  *(u64 *)pg_pointer(host->env, count, 8) = 0;
  *(u64 *)pg_pointer(host->env, size, 8) = 0;
  return 0;
}
u32 w2c_wasi__snapshot__preview1_environ_get(struct w2c_wasi__snapshot__preview1 *host, u64 array, u64 buffer) { return 0; }
u32 w2c_wasi__snapshot__preview1_fd_write(struct w2c_wasi__snapshot__preview1 *host, u32 fd, u64 vectors, u64 count, u64 written) {
  return pg_file_io(host->env, fd, vectors, count, 0, written, true, false);
}

void w2c_env_wasm_input_publish_js(struct w2c_env *host, u64 block) {
  uint8_t *base = pg_pointer(host, block, 444);
  atomic_store((_Atomic int32_t *)(base + 256), configuredWidth / 2);
  atomic_store((_Atomic int32_t *)(base + 256 + 4), configuredHeight / 2);
  atomic_store((_Atomic int32_t *)(base + 256 + 6 * 4), 1);
  atomic_store((_Atomic int32_t *)(base + 256 + 7 * 4), 1);
  atomic_store((_Atomic int32_t *)(base + 424), -1);
  atomic_store((_Atomic int32_t *)(base + 432), configuredWidth);
  atomic_store((_Atomic int32_t *)(base + 436), configuredHeight);
  // The engine reads this word where it would ask for Story/Sandbox on the
  // loading screen. Benchmarks always use the release (story) startup.
  int startMode=benchmarkEnabled()?1:configuredStartMode;
  atomic_store((_Atomic int32_t *)(base + 440), startMode);
  pg_log(startMode==1?"Start mode: Story Mode (continues the newest save, or a new game from the Prologue).":"Start mode: Sandbox Mode on the GTA V map.");
  atomic_store(&inputBlock, block);
  pg_log("Native controller bridge attached to the game's input block.");
}
void w2c_env_wasm_audio_publish_js(struct w2c_env *host, u64 ring, u32 capacity) {
  if (!capacity || (capacity & (capacity - 1))) wasm_rt_trap(WASM_RT_TRAP_OOB);
  pg_pointer(host, ring, 64 + (u64)capacity * 8);
  atomic_store(&audioCapacity, capacity);
  atomic_store(&audioRing, ring);
  pg_log("Native stereo audio ring attached.");
}

// Read-only game-state snapshot for the touch layout (no script native is called from UIKit).
// Bits: 1 player control off (IS_PLAYER_CONTROL_ON == false, single player: the player info's
// control-disabled flags at *(ped+4328)+936), 2 phone on screen (a CPhoneMgr flag at 19505653 that
// CPhoneMgr::Render/Delete and the phone-model render phase use; set while the phone is up),
// 4 cutscene playing (IS_CUTSCENE_PLAYING, *(19339168)+3215), 8 warning screen
// (IS_WARNING_MESSAGE_ACTIVE: 19577926 or 19577929 bit 0), 16 no local player yet.
uint32_t PGGameStatus(void){
 if(!atomic_load(&inputBlock))return 16;
 const uint8_t *m=(const uint8_t *)(void *)env.memory.data;uint64_t size=env.memory.size;
 uint32_t bits=0;uint64_t info,ped,playerInfo,cutscene;uint32_t controls;
 if(pg_context_u64(m,size,20159720,&info)&&info&&pg_context_u64(m,size,info+8,&ped)&&ped&&
    pg_context_u64(m,size,ped+4328,&playerInfo)&&playerInfo&&pg_context_u32(m,size,playerInfo+936,&controls)){
  if(controls)bits|=1;
 }else bits|=16;
 #define PG_BYTE(address) atomic_load_explicit((const _Atomic uint8_t *)(m+(address)),memory_order_relaxed)
 if(size>19577930){
  if(PG_BYTE(19505653))bits|=2;
  if(PG_BYTE(19577926)||(PG_BYTE(19577929)&1))bits|=8;
 }
 if(pg_context_u64(m,size,19339168,&cutscene)&&cutscene&&cutscene<size-3216&&PG_BYTE(cutscene+3215))bits|=4;
 #undef PG_BYTE
 return bits;
}
// Debug: copies [address, address+length) of engine memory (for finding state flags).
bool PGDebugReadMemory(uint64_t address,void *out,uint64_t length){
 if(!atomic_load(&inputBlock)||address>env.memory.size||length>env.memory.size-address)return false;
 memcpy(out,(const uint8_t *)(void *)env.memory.data+address,length);return true;
}
uint32_t PGCurrentTouchContext(void){
 if(!atomic_load(&inputBlock))return 0;
 return pg_touch_context((const uint8_t *)(void *)env.memory.data,env.memory.size);
}
void PGUpdateController(PGControllerState state, double elapsedSeconds) {
  uint64_t block = atomic_load(&inputBlock);
  if (!block) return;
  _Atomic uint8_t *keys = pg_pointer(&env, block, 444);
  const int codes[] = {0x20,0x11,0x52,0x46,0x51,0x45,0x1b,0x26,0x28,0x25,0x27};
  for (int i = 0; i < 11; i++) atomic_store(keys + codes[i], state.buttons & (1u << i) ? 0x80 : 0);
  atomic_store(keys + 0xa2, state.buttons & (1u << 1) ? 0x80 : 0);
  atomic_store(keys + 0xa0, state.buttons & (1u << 11) ? 0x80 : 0);
  atomic_store(keys + 0x09, state.buttons & (1u << 12) ? 0x80 : 0);
  atomic_store(keys + 0x56, state.buttons & (1u << 13) ? 0x80 : 0);
  atomic_store(keys + 0x48, state.buttons & (1u << 16) ? 0x80 : 0);
  atomic_store(keys + 0x64, state.buttons & (1u << 17) ? 0x80 : 0);
  atomic_store(keys + 0x66, state.buttons & (1u << 18) ? 0x80 : 0);
  atomic_store(keys + 0x68, state.buttons & (1u << 19) ? 0x80 : 0);
  atomic_store(keys + 0x62, state.buttons & (1u << 20) ? 0x80 : 0);
  atomic_store(keys + 0x47, state.buttons & (1u << 23) ? 0x80 : 0);
  atomic_store(keys + 0x57, state.leftY > .2f || (state.buttons & (1u << 14)) ? 0x80 : 0);
  atomic_store(keys + 0x53, state.leftY < -.2f || (state.buttons & (1u << 15)) ? 0x80 : 0);
  atomic_store(keys + 0x41, state.leftX < -.2f || (state.buttons & (1u << 21)) ? 0x80 : 0);
  atomic_store(keys + 0x44, state.leftX > .2f || (state.buttons & (1u << 22)) ? 0x80 : 0);
  atomic_store(keys + 0x0d, state.buttons & 1u ? 0x80 : 0);
  _Atomic int32_t *words = (_Atomic int32_t *)((uint8_t *)(void *)keys + 256);
  static PGLookRemainder lookRemainder;
  static bool weaponWheelHeld;
  bool wheel = (state.buttons & (1u << 12)) != 0 && !(state.buttons & (1u << 24));
  // Mouse coordinates follow the current back buffer (it can be resized live).
  int32_t width=atomic_load(words+44),height=atomic_load(words+45);
  if(width<320||height<180){width=960;height=540;}
  int32_t centerX=width/2,centerY=height/2,wheelRadius=height*4/9;
  if(wheel && !weaponWheelHeld){atomic_store(words,centerX);atomic_store(words+1,centerY);}
  weaponWheelHeld=wheel;
  int32_t dx, dy;
  if(wheel){
    pg_controller_look(&lookRemainder, 0, 0, 0, &dx, &dy);
    if(fabsf(state.rightX)>.1f || fabsf(state.rightY)>.1f){
      dx=centerX+(int32_t)lroundf(fmaxf(-1,fminf(1,state.rightX))*wheelRadius)-atomic_load(words);
      dy=centerY-(int32_t)lroundf(fmaxf(-1,fminf(1,state.rightY))*wheelRadius)-atomic_load(words+1);
    }
  }else pg_controller_look(&lookRemainder, state.rightX, state.rightY, elapsedSeconds, &dx, &dy);
  if(!wheel){dx+=state.lookDX;dy+=state.lookDY;}
  int32_t mouseX=atomic_load(words)+dx,mouseY=atomic_load(words+1)+dy;
  atomic_store(words,mouseX<0?0:mouseX>width-1?width-1:mouseX);
  atomic_store(words+1,mouseY<0?0:mouseY>height-1?height-1:mouseY);
  atomic_fetch_add(words + 2, dx);
  atomic_fetch_add(words + 3, dy);
  atomic_store(words + 5, (state.rightTrigger > .1f ? 1 : 0) | (state.leftTrigger > .1f ? 2 : 0));
}


// Virtual pad: packed so the engine thread reads one consistent sample.
// bits 0-15 buttons, then LX LY RX RY L2 R2 bytes (0x80 = centred stick).
static _Atomic uint64_t virtualPad = 0x0000808080800000ull;
static _Atomic bool virtualPadActive;
static uint8_t pg_pad_axis(float value, bool up) {
  if (!isfinite(value)) return 0x80;
  value = fmaxf(-1, fminf(1, value));
  if (up) value = -value;  // The engine's sticks use 0 for left and up.
  return (uint8_t)lroundf(127.5f + value * 127.5f);
}
static uint8_t pg_pad_trigger(float value) {
  return isfinite(value) ? (uint8_t)lroundf(fmaxf(0, fminf(1, value)) * 255) : 0;
}
void PGUpdateVirtualPad(PGPadState state) {
  uint64_t packed = (state.buttons & 0xffff) |
    (uint64_t)pg_pad_axis(state.leftX, false) << 16 | (uint64_t)pg_pad_axis(state.leftY, true) << 24 |
    (uint64_t)pg_pad_axis(state.rightX, false) << 32 | (uint64_t)pg_pad_axis(state.rightY, true) << 40 |
    (uint64_t)pg_pad_trigger(state.leftTrigger) << 48 | (uint64_t)pg_pad_trigger(state.rightTrigger) << 56;
  atomic_store(&virtualPad, packed);
  atomic_store(&virtualPadActive, true);
}
// SET_PLAYER_TARGETING_MODE (f58997): store menu preference 3, then apply it
// to the local player. Requested by the host, run here on the engine's own
// control-update thread.
void w2c_game_f36170(w2c_game*, u32, u32);
void w2c_game_f36175(w2c_game*, u64, u32, u32);
static _Atomic int32_t pendingTargetingMode = -1;
void PGSetTargetingMode(int32_t mode) { if (mode >= 0 && mode <= 3) atomic_store(&pendingTargetingMode, mode); }
// `instance` is the calling engine thread's own (its wasm stack pointer).
static void pg_apply_targeting_mode(w2c_game *instance) {
  int32_t mode = atomic_exchange(&pendingTargetingMode, -1);
  if (mode < 0) return;
  w2c_game_f36170(instance, 3, (u32)mode);
  uint64_t listeners = *(uint64_t *)pg_pointer(&env, 19571440, 8);
  if (listeners) w2c_game_f36175(instance, listeners, 0, (u32)mode);
  char line[96]; snprintf(line, sizeof line, "Targeting mode set to %d.", mode); pg_log(line);
}
void pg_virtual_pad_apply(w2c_game *instance, uint64_t pad) {
  if (pad == 12840656) pg_apply_targeting_mode(instance);
  if (pad != 12840656 || !atomic_load(&virtualPadActive)) return;
  uint64_t packed = atomic_load(&virtualPad);
  uint8_t *base = pg_pointer(&env, pad, 136);
  _Atomic uint32_t *buttons = (_Atomic uint32_t *)(base + 12);
  uint32_t bits = (uint32_t)(packed & 0xffff);
  uint8_t l2 = packed >> 48, r2 = packed >> 56;
  // Analog triggers also count as pressed buttons past a small threshold.
  if (l2 > 30) bits |= 1; if (r2 > 30) bits |= 2;
  atomic_store(buttons, atomic_load(buttons) | bits);
  for (int i = 0; i < 4; i++) atomic_store((_Atomic uint8_t *)(base + 20 + i), (uint8_t)(packed >> (16 + 8 * i)));
  atomic_store((_Atomic uint8_t *)(base + 24), l2);
  atomic_store((_Atomic uint8_t *)(base + 25), r2);
}
// The core of IS_PAUSE_MENU_ACTIVE (f52482 -> f36254): either frontend flag.
bool PGPauseMenuActive(void) {
  if (!atomic_load(&inputBlock) || env.memory.size < 19566112) return false;
  const uint8_t *memory = (const uint8_t *)(void *)env.memory.data;
  return ((atomic_load_explicit((const _Atomic uint8_t *)(memory + 19565906), memory_order_relaxed) |
           atomic_load_explicit((const _Atomic uint8_t *)(memory + 19566104), memory_order_relaxed)) & 1) != 0;
}
// PREF_TARGET_CONFIG: 0 traditional lock, 1 assisted, 2 assisted free, 3 free aim.
int32_t PGTargetingMode(void) {
  if (!atomic_load(&inputBlock) || env.memory.size < 19566128) return -1;
  return atomic_load_explicit((const _Atomic int32_t *)(void *)((const uint8_t *)(void *)env.memory.data + 19566124), memory_order_relaxed);
}
int32_t PGLastInputDevice(void) {
  if (!atomic_load(&inputBlock) || env.memory.size < 24627140) return -3;
  return atomic_load_explicit((const _Atomic int32_t *)(void *)((const uint8_t *)(void *)env.memory.data + 24627136), memory_order_relaxed);
}

void PGFillAudio(float *left, float *right, uint32_t count) {
  memset(left, 0, count * sizeof(float)); memset(right, 0, count * sizeof(float));
  uint64_t ring = atomic_load(&audioRing);
  if (!ring) return;
  uint32_t capacity = atomic_load(&audioCapacity);
  _Atomic uint32_t *header = pg_pointer(&env, ring, 64 + (u64)capacity * 8);
  float *data = (float *)((uint8_t *)(void *)header + 64);
  uint32_t read = atomic_load(header + 1), write = atomic_load(header);
  uint32_t available = write - read;
  uint32_t take = available < count ? available : count;
  if (take > capacity) take = capacity;
  for (uint32_t i = 0; i < take; i++) {
    uint32_t at = ((read + i) & (capacity - 1)) * 2;
    left[i] = data[at]; right[i] = data[at + 1];
  }
  atomic_store(header + 1, read + take);
  atomic_fetch_add(header + 3, 1);
}

static char *configuredQuality[32];static unsigned configuredQualityCount;
void PGConfigureEngine(const char *const *quality,unsigned count,int width,int height,int frameLimit){
  if(atomic_load(&started))return;
  for(unsigned i=0;i<configuredQualityCount;i++)free(configuredQuality[i]);
  configuredQualityCount=0;
  for(unsigned i=0;i<count&&i<32;i++)configuredQuality[configuredQualityCount++]=strdup(quality[i]);
  if(width>=320&&width<=3840&&height>=180&&height<=2160){configuredWidth=width&~1;configuredHeight=height&~1;}
  if(frameLimit>=0&&frameLimit<=4)configuredFrameLimit=frameLimit;
}
void PGSetStartMode(int32_t mode){
  if(atomic_load(&started))return;
  if(mode==1||mode==2)configuredStartMode=mode;
}
void PGSetBackBufferSize(int width,int height){
  uint64_t block=atomic_load(&inputBlock);
  if(!block||width<320||height<180||width>3840||height>2160)return;
  uint8_t *base=pg_pointer(&env,block,444);
  atomic_store((_Atomic int32_t *)(base+432),width&~1);
  atomic_store((_Atomic int32_t *)(base+436),height&~1);
}
static void *boot(void *ignored) {
  // Real iOS must budget against its Jetsam allowance. Simulator runs opt in
  // with an explicit modeled ceiling so ordinary performance baselines match.
  const char *guard=getenv("PG_MEMORY_GUARD");nativeMemoryGuard=guard?atoi(guard)==1:!TARGET_OS_SIMULATOR;
#if TARGET_OS_SIMULATOR
  const char *limit=getenv("PG_STREAM_MEMORY_LIMIT_MB");
  if(limit){char *end;unsigned long mb=strtoul(limit,&end,10);if(end!=limit&&!*end&&mb>=2048&&mb<=8192)simulatedProcessLimit=(uint64_t)mb*1048576;}
#endif
  if(nativeMemoryGuard)pg_log("Native streaming memory guard enabled with 384 MB of reserve.");
  pg_assets_prewarm();
  nativeEngineCores=pg_engine_core_configuration(getenv("PG_ENGINE_CORES"));
  char coresOption[32];snprintf(coresOption,sizeof coresOption,"-numCores=%u",nativeEngineCores);
  char coresLog[96];snprintf(coresLog,sizeof coresLog,"Native engine worker configuration: %u logical cores.",nativeEngineCores);pg_log(coresLog);
  wasm_rt_init();
  pg_log("Reserving 4095 MB virtual engine memory, starting with a 3328 MB shared heap.");
#if defined(PG_HAS_ARM64_SHARED_VECTORS) && !defined(PG_SHARED_SIMD_BYTEWISE)
  pg_log("Shared vector memory uses native ARM64 instructions with bounds checks.");
#else
  pg_log("Shared vector memory uses bytewise atomic copies with bounds checks.");
#endif
  env.memory.pages = 3328ull*1024*1024/wasm2c_game_pagesize_env_memory;
  env.memory.max_pages = 4095ull*1024*1024/wasm2c_game_pagesize_env_memory;
  env.memory.page_size = wasm2c_game_pagesize_env_memory;
  env.memory.size = env.memory.pages * env.memory.page_size;
  env.memory.is64 = true;
  uint64_t capacity=env.memory.max_pages*env.memory.page_size;
  // The full maximum is mapped up front, then an inaccessible guard region:
  // unchecked builds (PG_UNCHECKED_MEMORY) rely on it so that an access past
  // the end faults instead of touching unrelated memory.
  // Small enough for apps without the extended-address-space entitlement.
  const uint64_t guardBytes=64ull<<20;
  void *allocation=mmap(NULL,capacity+guardBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  if (allocation==MAP_FAILED) { pg_log("iOS could not reserve the engine memory."); return NULL; }
  if (mprotect((uint8_t *)allocation+capacity,guardBytes,PROT_NONE)) pg_log("Engine memory guard region could not be protected.");
  env.memory.data=(_Atomic volatile uint8_t *)allocation;
  env.memory.data_end = env.memory.data + capacity;
  pthread_mutex_init(&env.memory.mem_lock, NULL);
  wasm_rt_trap_t trap = wasm_rt_impl_try();
  if (trap) {
    char message[512];
    snprintf(message, sizeof(message), "Native boot stopped: %s%s%s", wasm_rt_strerror(trap),
             missingImport[0] ? " — " : "", missingImport);
    pg_log(message);
    return NULL;
  }
  pg_threads_main(&env);
  wasm2c_game_instantiate(&env.game, &env, &wasi);
  uint32_t actual = w2c_game_htons(&env.game, 0x1234);
  char message[128];
  snprintf(message, sizeof(message), "Real engine export executed as ARM64: htons(0x1234) = 0x%04x", actual);
  pg_log(message);
  if (actual != 0x3412) { pg_log("Native execution produced an incorrect result."); return NULL; }
  pg_log("Running the real engine's static constructors.");
  w2c_game_0x5F_wasm_call_ctors(&env.game);
  pg_log("Constructors completed; calling the game entry point.");
  char widthOption[32],heightOption[32],frameOption[32];
  snprintf(widthOption,sizeof widthOption,"-width=%d",configuredWidth);
  snprintf(heightOption,sizeof heightOption,"-height=%d",configuredHeight);
  snprintf(frameOption,sizeof frameOption,"-frameLimit=%d",benchmarkEnabled()?0:configuredFrameLimit);
  const char *base[]={"playgta5","-rootdir=/game/","-wgpu","-nodisplaycalibration","-noSocialClub","-pc:nosocialclub","-nonetwork","-output",widthOption,heightOption,"-forceResolution","-fastscriptcore","-Script_all=warning","-replay_all=warning",frameOption,coresOption};
  const char *defaultQuality[]={"-shaderQuality=1","-textureQuality=0","-pedVariety=0","-vehicleVariety=0","-shadowQuality=-1","-reflectionQuality=0","-particleQuality=0","-grassQuality=0","-cityDensity=0","-lodScale=0","-pedLodBias=0","-vehicleLodBias=0"};
  const char *options[64];unsigned optionCount=0;
  for(unsigned i=0;i<sizeof base/sizeof *base;i++)options[optionCount++]=base[i];
  // Benchmarks keep the measured low profile so results stay comparable.
  if(configuredQualityCount&&!benchmarkEnabled())for(unsigned i=0;i<configuredQualityCount;i++)options[optionCount++]=configuredQuality[i];
  else for(unsigned i=0;i<sizeof defaultQuality/sizeof *defaultQuality;i++)options[optionCount++]=defaultQuality[i];
  snprintf(message,sizeof message,"Graphics: %dx%d, frame limit %d, %u quality options.",configuredWidth,configuredHeight,benchmarkEnabled()?0:configuredFrameLimit,configuredQualityCount);pg_log(message);
  u64 stack=w2c_game_emscripten_stack_get_current(&env.game);
  u64 argv=(stack-4096)&~(u64)15;
  w2c_game_0x5Femscripten_stack_restore(&env.game,argv);
  u64 *arguments=pg_pointer(&env,argv,4096);u64 text=argv+512;
  unsigned argc=optionCount;
  for(unsigned i=0;i<argc;i++){size_t len=strlen(options[i])+1;arguments[i]=text;memcpy(pg_pointer(&env,text,len),options[i],len);text+=len;}
  if(benchmarkEnabled()) {
    const char *iterationText=getenv("PG_BENCHMARK_ITERATIONS");unsigned iterations=1;
    if(iterationText){char *end;unsigned long parsed=strtoul(iterationText,&end,10);if(end!=iterationText&&!*end&&parsed>=1&&parsed<=10)iterations=(unsigned)parsed;}
    char iterationOption[48];snprintf(iterationOption,sizeof iterationOption,"-benchmarkIterations=%u",iterations);
    const char *extra[]={"-benchmark",iterationOption,"-benchmarkFrameTimes"};
    for(unsigned i=0;i<sizeof(extra)/sizeof(*extra);i++){size_t len=strlen(extra[i])+1;arguments[argc++]=text;memcpy(pg_pointer(&env,text,len),extra[i],len);text+=len;}
    const char *pass=getenv("PG_BENCHMARK_PASS");if(pass&&*pass){char option[64];snprintf(option,sizeof option,"-benchmarkPass=%d",atoi(pass));size_t len=strlen(option)+1;arguments[argc++]=text;memcpy(pg_pointer(&env,text,len),option,len);text+=len;}
    pg_log("Starting the engine's built-in graphics benchmark.");
  }
  const char *streamerPercentage=getenv("PG_STREAMER_PERCENTAGE");
  if(streamerPercentage&&*streamerPercentage){
    char *end;double fraction=strtod(streamerPercentage,&end);
    if(end!=streamerPercentage&&!*end&&isfinite(fraction)&&fraction>=.1&&fraction<=.95){
      char option[80];snprintf(option,sizeof option,"-percentageForStreamer=%.3f",fraction);
      size_t len=strlen(option)+1;arguments[argc++]=text;memcpy(pg_pointer(&env,text,len),option,len);text+=len;
      snprintf(message,sizeof message,"Native streaming budget experiment: %.3f of engine video-memory budget.",fraction);pg_log(message);
    }
  }
  arguments[argc]=0;
  uint32_t result=w2c_game_0x5F_main_argc_argv(&env.game,argc,argv);
  snprintf(message, sizeof(message), "Game entry point returned %u", result);
  pg_log(message);
  return NULL;
}

void PGStartEngine(const char *path, const char *filesRoot, PGLogCallback callback, void *context) {
  if (atomic_exchange(&started, true)) return;
  manifestPath = strdup(path);
  pg_files_init(filesRoot);
  logCallback = callback; logContext = context;
  pg_assets_configure(path, filesRoot);
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
  pthread_t thread;
  int result = pthread_create(&thread, &attributes, boot, NULL);
  pthread_attr_destroy(&attributes);
  if (result) { pg_log("Could not create the native engine thread."); return; }
  pthread_detach(thread);
}

#include <execinfo.h>
#include <mach-o/dyld.h>
void pg_record_trap(int code) {
  void *frames[20];int count=backtrace(frames,20);char line[160];
  snprintf(line,sizeof line,"Native trap %d; app image base %p",code,_dyld_get_image_header(0));pg_log(line);
  for(int i=0;i<count;i++){snprintf(line,sizeof line,"  native frame %d: %p",i,frames[i]);pg_log(line);}
}

#include "NativeGraphics.h"
uint32_t PGGraphicsNotify(uint64_t address){return pg_atomic_notify(&env.memory,address,UINT32_MAX);}
// The native Metal renderer sleeps on the ring head word like an engine thread (timeout in nanoseconds, -1: none).
uint32_t PGGraphicsWait(uint64_t address,uint32_t expected,int64_t timeoutNs){return pg_atomic_wait32(&env.memory,address,expected,(uint64_t)timeoutNs);}
void w2c_env_wgpu_start_worker(struct w2c_env *host,u64 ring,u64 size,u64 debug){
  pg_log("Connecting game graphics commands to native Metal.");
  PGStartGraphics((void *)env.memory.data,env.memory.max_pages*env.memory.page_size,ring,size,debug);
}
