// SystemCheck: the checks written for the iOS 16.5 port to the Redmi K40, in one application, a tab each -- GPU (what
// was GPU Check: every graphics capability a game may need, tested one at a time), Metal (Metal Check: what an
// application finds of Metal), Video (a clip played through AVPlayer), Sensors (Sensor Check: every sensor and input,
// live) and Motion (Motion Test: a phone in 3D that turns as this one does). On an iPhone it is an ordinary
// application. Nothing runs by itself: a tab's Run button, or a URL from the computer --
//     systemcheck://<gpu|metal|video|sensors|motion>[/run]
// (the tab brought to the front, and its tests started). The tests' logs, Documents/gpucheck.log and metalcheck.log,
// and their lines on /dev/console ("gpucheck: ...", "metalcheck: ...", "videocheck: ...") are what they were in the
// separate applications. build.sh builds it into SystemCheck.ipa (mkicon.py its icon).
#import "check.h"
#include <signal.h>

#pragma mark the crash handler

#define HOOKS 8

static void (*g_on_signal[HOOKS])(int);
static void (*g_on_exception[HOOKS])(NSException *);
static int g_hooks;

static void
crash_signal(int signal, siginfo_t *info, void *context)
{
	for (int i = 0; i < g_hooks; i++) {
		if (g_on_signal[i] != NULL) {
			g_on_signal[i](signal);
		}
	}
	/* (SA_RESETHAND: the default action again; the signal, blocked in here, takes the application down on return) */
	raise(signal);
}

static void
crash_exception(NSException *exception)
{
	for (int i = 0; i < g_hooks; i++) {
		if (g_on_exception[i] != NULL) {
			g_on_exception[i](exception);
		}
	}
}

void
check_watch_crashes(void (*on_signal)(int signal), void (*on_exception)(NSException *exception))
{
	static char stack[64 * 1024];
	static const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS };

	if (g_hooks == 0) {
		stack_t alternate = { .ss_sp = stack, .ss_size = sizeof(stack), .ss_flags = 0 };
		struct sigaction action;

		/* (a stack of its own: a stack overflow on the main thread is caught too) */
		(void)sigaltstack(&alternate, NULL);
		memset(&action, 0, sizeof(action));
		action.sa_sigaction = crash_signal;
		action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
		sigemptyset(&action.sa_mask);
		for (size_t k = 0; k < sizeof(signals) / sizeof(signals[0]); k++) {
			(void)sigaction(signals[k], &action, NULL);
		}
		signal(SIGPIPE, SIG_IGN);
		NSSetUncaughtExceptionHandler(crash_exception);
	}
	if (g_hooks < HOOKS) {
		g_on_signal[g_hooks] = on_signal;
		g_on_exception[g_hooks] = on_exception;
		g_hooks++;
	}
}

/* dyld's: where the shared cache is (iOS 13 and later); an arm64 iPhone's cache is linked at 0x180000000 */
extern const void *_dyld_get_shared_cache_range(size_t *length);

NSString *
check_backtrace(NSException *exception)
{
	NSMutableString *text = [NSMutableString string];
	size_t length = 0;
	const void *cache = _dyld_get_shared_cache_range(&length);
	NSArray<NSNumber *> *addresses = exception.callStackReturnAddresses;

	[text appendFormat:@"slide %#lx:", cache != NULL ? (unsigned long)((uintptr_t)cache - 0x180000000UL) : 0UL];
	for (NSUInteger i = 0; i < addresses.count && i < 24; i++) {
		[text appendFormat:@" %#lx", (unsigned long)addresses[i].unsignedLongValue];
	}
	return text;
}

#pragma mark the tabs

static const struct tab {
	__unsafe_unretained NSString *name, *title, *symbol;
	UIViewController *(*make)(void);
	BOOL navigation;        /* in a navigation controller (a title, a Run button) */
	void (*run)(void);      /* what /run does, if anything */
} tabs[] = {
	{ @"gpu", @"GPU", @"cpu", gpu_controller, YES, gpu_run },
	{ @"metal", @"Metal", @"cube", metal_controller, YES, metal_run },
	{ @"video", @"Video", @"play.rectangle", video_controller, NO, video_run },
	{ @"sensors", @"Sensors", @"gauge", sensor_controller, YES, NULL },
	{ @"motion", @"Motion", @"gyroscope", motion_controller, NO, NULL },
};
#define TAB_COUNT ((NSUInteger)(sizeof(tabs) / sizeof(tabs[0])))

@interface CheckDelegate : UIResponder <UIApplicationDelegate, UITabBarControllerDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) UITabBarController *tabs;
@end

@implementation CheckDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
	NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
	NSInteger last = [NSUserDefaults.standardUserDefaults integerForKey:@"tab"];

	for (NSUInteger i = 0; i < TAB_COUNT; i++) {
		UIViewController *c = tabs[i].make();

		if (tabs[i].navigation) {
			c = [[UINavigationController alloc] initWithRootViewController:c];
		}
		c.tabBarItem = [[UITabBarItem alloc] initWithTitle:tabs[i].title image:[UIImage systemImageNamed:tabs[i].symbol]
		    tag:(NSInteger)i];
		[controllers addObject:c];
	}
	self.tabs = [UITabBarController new];
	self.tabs.viewControllers = controllers;
	self.tabs.delegate = self;
	self.tabs.selectedIndex = last >= 0 && last < (NSInteger)TAB_COUNT ? (NSUInteger)last : 0;
	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = self.tabs;
	[self.window makeKeyAndVisible];
	return YES;
}

- (void)tabBarController:(UITabBarController *)controller didSelectViewController:(UIViewController *)selected
{
	[NSUserDefaults.standardUserDefaults setInteger:(NSInteger)controller.selectedIndex forKey:@"tab"];
}

/* systemcheck://gpu, systemcheck://gpu/run */
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options
{
	for (NSUInteger i = 0; i < TAB_COUNT; i++) {
		if ([url.host isEqualToString:tabs[i].name]) {
			self.tabs.selectedIndex = i;
			[NSUserDefaults.standardUserDefaults setInteger:(NSInteger)i forKey:@"tab"];
			if ([url.path isEqualToString:@"/run"] && tabs[i].run != NULL) {
				tabs[i].run();
			}
			return YES;
		}
	}
	return NO;
}

@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil, NSStringFromClass(CheckDelegate.class));
	}
}
