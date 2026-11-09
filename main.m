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
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/getsect.h>
#include <signal.h>
#include <sys/ucontext.h>

#pragma mark the crash handler

#define HOOKS 8

static void (*g_on_signal[HOOKS])(int);
static void (*g_on_exception[HOOKS])(NSException *);
static int g_hooks;
static int g_crash_console = -1;

/* " image+0xoffset" (or " 0xaddress" where no image holds it) appended to line at *n */
static void
crash_name(char *line, size_t size, int *n, uintptr_t address)
{
	Dl_info info;

	/* (a return address saved by arm64e code carries its pointer signature above the address bits) */
	address &= 0x0000000fffffffffUL;
	if (*n >= (int)size) {
		return;
	}
	if (address != 0 && dladdr((const void *)address, &info) && info.dli_fname != NULL) {
		const char *base = strrchr(info.dli_fname, '/');

		*n += snprintf(line + *n, size - (size_t)*n, " %s+%#lx", base != NULL ? base + 1 : info.dli_fname,
		    (unsigned long)(address - (uintptr_t)info.dli_fbase));
	} else {
		*n += snprintf(line + *n, size - (size_t)*n, " %#lx", (unsigned long)address);
	}
}

/*
 * Where the crash was, by image: pc, lr and the frame chain as "image+offset", one line on /dev/console. The kernel's
 * fault line gives the same addresses bare, and a library outside the shared cache moves every launch, so a crash in
 * one of the port's own libraries could not be named afterwards (a Core Image crash in the GL library, 2026-11-09).
 * dladdr is not async-signal-safe; this runs once, on the way down.
 */
static void
crash_where(int signal, void *context)
{
	ucontext_t *uc = context;
	char line[1024];
	int n;
	uintptr_t fp;

	if (uc == NULL || uc->uc_mcontext == NULL || g_crash_console < 0) {
		return;
	}
	n = snprintf(line, sizeof(line), "systemcheck: crash: signal %d at pc", signal);
	crash_name(line, sizeof(line), &n, (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
	n += n < (int)sizeof(line) ? snprintf(line + n, sizeof(line) - (size_t)n, ", lr") : 0;
	crash_name(line, sizeof(line), &n, (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
	n += n < (int)sizeof(line) ? snprintf(line + n, sizeof(line) - (size_t)n, ", frames") : 0;
	fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
	for (int i = 0; i < 12 && fp != 0 && (fp & 7) == 0; i++) {
		const uintptr_t *frame = (const uintptr_t *)fp;

		crash_name(line, sizeof(line), &n, frame[1]);
		fp = frame[0] & 0x0000000fffffffffUL;
	}
	if (n > (int)sizeof(line) - 2) {
		n = (int)sizeof(line) - 2;
	}
	line[n++] = '\n';
	(void)write(g_crash_console, line, (size_t)n);

	/*
	 * And the lazy-binding pointers of the image lr is in, when it has them: how many are zero, and where -- a call
	 * through one that became zero is how the GL library's crashes of 2026-11-09 ended (pc 0). Every one of them zero
	 * would be a page lost; a run of them, something writing past its own memory.
	 */
	Dl_info info;
	uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss) & 0x0000000fffffffffUL;
	unsigned long size = 0;
	const uint64_t *lazy;

	if (!dladdr((const void *)lr, &info) || info.dli_fbase == NULL ||
	    (lazy = (const uint64_t *)getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA",
	    "__la_symbol_ptr", &size)) == NULL || size < 8) {
		return;
	}
	unsigned count = (unsigned)(size / 8), zero = 0, first = ~0u, last = 0, runs = 0, own = 0;
	uintptr_t low = ~(uintptr_t)0, high = 0;
	const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
	const struct load_command *lc = (const struct load_command *)(mh + 1);
	intptr_t slide = 0;

	/* the image's own range (its segments), so that a pointer still at its own __stub_helper -- never bound -- shows */
	for (uint32_t k = 0; k < mh->ncmds; k++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
		if (lc->cmd == LC_SEGMENT_64) {
			const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;

			if (strcmp(sg->segname, "__TEXT") == 0) {
				slide = (intptr_t)mh - (intptr_t)sg->vmaddr;
			}
			if (sg->vmsize != 0 && strcmp(sg->segname, "__PAGEZERO") != 0) {
				low = sg->vmaddr < low ? (uintptr_t)sg->vmaddr : low;
				high = sg->vmaddr + sg->vmsize > high ? (uintptr_t)(sg->vmaddr + sg->vmsize) : high;
			}
		}
	}
	low += (uintptr_t)slide;
	high += (uintptr_t)slide;
	for (unsigned i = 0; i < count; i++) {
		if (lazy[i] == 0) {
			runs += i == 0 || lazy[i - 1] != 0;
			zero++;
			first = first == ~0u ? i : first;
			last = i;
		} else if ((lazy[i] & 0x0000000fffffffffUL) >= low && (lazy[i] & 0x0000000fffffffffUL) < high) {
			own++;
		}
	}
	n = snprintf(line, sizeof(line), "systemcheck: crash: %s's lazy pointers at +%#lx: %u of %u zero", strrchr(info.dli_fname,
	    '/') != NULL ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname, (unsigned long)((uintptr_t)lazy -
	    (uintptr_t)info.dli_fbase), zero, count);
	if (zero != 0 && n < (int)sizeof(line)) {
		n += snprintf(line + n, sizeof(line) - (size_t)n, " in %u runs, from entry %u (+%#lx) to %u (+%#lx)", runs, first,
		    (unsigned long)((uintptr_t)&lazy[first] - (uintptr_t)info.dli_fbase), last,
		    (unsigned long)((uintptr_t)&lazy[last] - (uintptr_t)info.dli_fbase));
	}
	if (n < (int)sizeof(line)) {
		n += snprintf(line + n, sizeof(line) - (size_t)n, "; %u point into the image itself (its stub helpers: never bound)",
		    own);
	}

	/* the GOT, whose dyld_stub_binder entry the stub helpers jump through */
	unsigned long got_size = 0;
	const uint64_t *got = (const uint64_t *)getsectiondata(mh, "__DATA_CONST", "__got", &got_size);

	if (got == NULL) {
		got = (const uint64_t *)getsectiondata(mh, "__DATA", "__got", &got_size);
	}
	if (got != NULL && n < (int)sizeof(line)) {
		unsigned gzero = 0;

		for (unsigned i = 0; i < got_size / 8; i++) {
			gzero += got[i] == 0;
		}
		n += snprintf(line + n, sizeof(line) - (size_t)n, "; GOT: %u of %lu zero", gzero, got_size / 8);
	}

	/* and the very pointer the call before lr went through: "bl stub", the stub "nop; ldr x16, =ptr; br x16" */
	const uint32_t *call = (const uint32_t *)(lr - 4);

	if ((*call & 0xfc000000u) == 0x94000000u && n < (int)sizeof(line)) {
		int32_t imm = (int32_t)(*call << 6) >> 6;
		const uint32_t *stub = call + imm;
		const uint32_t *ldr = (stub[0] & 0xff00001fu) == 0x58000010u ? stub : stub + 1;

		if ((uintptr_t)stub >= low && (uintptr_t)stub < high && (*ldr & 0xff00001fu) == 0x58000010u) {
			int32_t lit = (int32_t)((*ldr >> 5) & 0x7ffff) << 13 >> 13;
			const uint64_t *ptr = (const uint64_t *)((uintptr_t)ldr + (intptr_t)lit * 4);
			uint64_t value = *ptr & 0x0000000fffffffffUL;

			n += snprintf(line + n, sizeof(line) - (size_t)n, "; the call's pointer +%#lx = %#llx (%s)",
			    (unsigned long)((uintptr_t)ptr - (uintptr_t)mh), (unsigned long long)value,
			    value == 0 ? "zero" : value >= low && value < high ? "into the image: its stub helper" : "bound");
		}
	}
	if (n > (int)sizeof(line) - 2) {
		n = (int)sizeof(line) - 2;
	}
	line[n++] = '\n';
	(void)write(g_crash_console, line, (size_t)n);
}

static void
crash_signal(int signal, siginfo_t *info, void *context)
{
	(void)info;
	crash_where(signal, context);
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
		g_crash_console = open("/dev/console", O_WRONLY | O_NOCTTY);
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
