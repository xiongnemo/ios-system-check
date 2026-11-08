// System Check's Video tab (the K40 port's B9 test): a video played the way an application plays one (AVPlayer into
// an AVPlayerLayer), a 6 s clip of ffmpeg's testsrc2 bundled with it (test.mp4), looped while the tab is on the
// screen. The picture is for a screenshot; the lines on /dev/console say what the player says, once a second for 20 s
// after the tab first comes to the front (and after Run or systemcheck://video/run): "videocheck: ..." -- its status,
// whether the time moves, the item's error if any, and the layer's readyForDisplay.
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <unistd.h>
#import "check.h"

static int g_console = -1;

static void say(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void
say(NSString *format, ...)
{
	va_list arguments;
	NSString *text;
	NSData *bytes;

	va_start(arguments, format);
	text = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	NSLog(@"videocheck: %@", text);
	bytes = [[NSString stringWithFormat:@"videocheck: %@\n", text] dataUsingEncoding:NSASCIIStringEncoding
	    allowLossyConversion:YES];
	if (g_console >= 0) {
		(void)write(g_console, bytes.bytes, bytes.length);
	}
}

@interface VideoController : UIViewController
- (void)run;
@end

@implementation VideoController {
	AVPlayer *_player;
	AVPlayerLayer *_layer;
	UILabel *_status;
	NSTimer *_timer;
	unsigned _ticks;
	double _last;
	BOOL _ran;
}

- (void)viewDidLoad
{
	NSURL *url = [[NSBundle mainBundle] URLForResource:@"test" withExtension:@"mp4"];
	UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];

	[super viewDidLoad];
	self.view.backgroundColor = UIColor.darkGrayColor;
	_status = [UILabel new];
	_status.numberOfLines = 0;
	_status.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	_status.textColor = UIColor.whiteColor;
	[self.view addSubview:_status];
	[run setTitle:@"Run" forState:UIControlStateNormal];
	run.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
	[run addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
	run.tag = 1;
	[self.view addSubview:run];
	if (url == nil) {
		_status.text = @"no test.mp4 in the bundle";
		say(@"no test.mp4 in the bundle");
		return;
	}
	_player = [AVPlayer playerWithURL:url];
	_player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
	_layer = [AVPlayerLayer playerLayerWithPlayer:_player];
	_layer.videoGravity = AVLayerVideoGravityResizeAspect;
	[self.view.layer addSublayer:_layer];
	[[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
	    object:_player.currentItem queue:nil usingBlock:^(NSNotification *note) {
		[self->_player seekToTime:kCMTimeZero];
		say(@"looped");
	}];
}

- (void)viewDidLayoutSubviews
{
	CGRect all = self.view.bounds;
	UIEdgeInsets safe = self.view.safeAreaInsets;
	CGFloat top = MAX(safe.top, 20) + 60, height = all.size.width * 9 / 16;

	[super viewDidLayoutSubviews];
	[self.view viewWithTag:1].frame = CGRectMake(all.size.width - 96, MAX(safe.top, 20) + 8, 80, 40);
	_layer.frame = CGRectMake(0, top, all.size.width, height);
	_status.frame = CGRectMake(16, top + height + 16, all.size.width - 32, 120);
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	[_player play];
	if (!_ran) {
		[self run];
	}
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	[_player pause];
}

/* from the start, and what the player says once a second for 20 s */
- (void)run
{
	if (_player == nil) {
		return;
	}
	_ran = YES;
	_ticks = 0;
	_last = -1;
	[_timer invalidate];
	[_player seekToTime:kCMTimeZero];
	[_player play];
	say(@"playing test.mp4");
	_timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)tick
{
	AVPlayerItem *item = _player.currentItem;
	double now = CMTimeGetSeconds(_player.currentTime);
	NSString *line;

	if (++_ticks > 20) {
		[_timer invalidate];
		_timer = nil;
		return;
	}
	line = [NSString stringWithFormat:@"t=%u s: item status %ld, time %.2f (%s), rate %.1f, readyForDisplay %d, "
	    "presentation %.0fx%.0f%@", _ticks, (long)item.status, now, now != _last ? "moving" : "STILL", _player.rate,
	    (int)_layer.readyForDisplay, item.presentationSize.width, item.presentationSize.height, item.error != nil ?
	    [NSString stringWithFormat:@", error %@", item.error.localizedDescription] : @""];
	say(@"%@", line);
	_status.text = line;
	_last = now;
}

@end

static VideoController *g_controller;

UIViewController *
video_controller(void)
{
	if (g_controller == nil) {
		g_console = open("/dev/console", O_WRONLY | O_NOCTTY);
		g_controller = [VideoController new];
	}
	return g_controller;
}

void
video_run(void)
{
	VideoController *c = (VideoController *)video_controller();

	[c loadViewIfNeeded];
	[c run];
}
