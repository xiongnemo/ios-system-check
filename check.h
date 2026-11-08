// What the parts of System Check share: each tab's controller, what a URL can ask of a tab, and the one crash handler
// of the process.
#import <UIKit/UIKit.h>

/* the tabs' controllers, made once (main.m puts the list-like ones in a navigation controller) */
UIViewController *gpu_controller(void);         /* gpu.m: GPU Check */
UIViewController *metal_controller(void);       /* metal.m: Metal Check */
UIViewController *video_controller(void);       /* video.m: a video through AVPlayer */
UIViewController *sensor_controller(void);      /* sensors.m: Sensor Check */
UIViewController *motion_controller(void);      /* motion.m: Motion Test */

/* systemcheck://<tab>/run: the tab's tests, as its Run button would start them (the tab is in front by then) */
void gpu_run(void);
void metal_run(void);
void video_run(void);

/*
 * The process's one crash handler, shared by the tabs that keep a log of what they ran: on a fatal signal each
 * on_signal is called (it may only write(2) and fsync(2), to descriptors opened before), then the signal takes the
 * application down as it would have; on an uncaught exception, each on_exception. Either may be NULL.
 */
void check_watch_crashes(void (*on_signal)(int signal), void (*on_exception)(NSException *exception));
