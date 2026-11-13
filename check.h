// What the parts of System Check share: each tab's controller, what a URL can ask of a tab, and the one crash handler
// of the process.
#import <UIKit/UIKit.h>

/* the tabs' controllers, made once (main.m puts the list-like ones in a navigation controller) */
UIViewController *gpu_controller(void);         /* gpu.m: GPU Check */
UIViewController *metal_controller(void);       /* metal.m: Metal Check */
UIViewController *video_controller(void);       /* video.m: a video through AVPlayer */
UIViewController *sensor_controller(void);      /* sensors.m: Sensor Check */
UIViewController *motion_controller(void);      /* motion.m: Motion Test */
UIViewController *gps_controller(void);         /* gps.m: the satellites, the fix (after the GPS Status app) */

/* systemcheck://<tab>/run: the tab's tests, as its Run button would start them (the tab is in front by then) */
void gpu_run(void);
void metal_run(void);
void video_run(void);
void gps_run(void);                             /* a DEMO sky: made-up satellites, to check the drawing */

/* Whether the GPU tab has made an SKView / SCNView in this process (gpu.m sets them). SpriteKit and SceneKit pick
   OpenGL ES or Metal once a process, so the Metal tab's spritekit and scenekit tests mean something only before. */
extern BOOL check_gl_spritekit_used, check_gl_scenekit_used;

/*
 * The process's one crash handler, shared by the tabs that keep a log of what they ran: on a fatal signal each
 * on_signal is called (it may only write(2) and fsync(2), to descriptors opened before), then the signal takes the
 * application down as it would have; on an uncaught exception, each on_exception. Either may be NULL.
 */
void check_watch_crashes(void (*on_signal)(int signal), void (*on_exception)(NSException *exception));

/* the fatal signal's "signal N at pc image+0x..., lr ..., frames ..." (newline-terminated), set before the on_signal
   hooks run, so that a tab's log says where as well as which test: the console line alone is lost when the kernel's
   message buffer wraps in a long run (2026-11-09) */
extern char check_crash_where[1024];

/* where an exception was thrown, for a log line: "slide 0x...: 0x... 0x..." -- the shared cache's slide and the
   return addresses, which the port's tools turn into names (work/wsl/dsc-a2s.sh SLIDE ADDR...) */
NSString *check_backtrace(NSException *exception);
