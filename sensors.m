// System Check's Sensors tab (what was Sensor Check): every sensor and hardware input an iOS application can reach,
// live on one screen, each with whether this device has it -- the light (and the screen's brightness), proximity,
// accelerometer, gyroscope, magnetometer, device motion, barometer, pedometer and activity, compass, location,
// battery, microphone, cameras, Bluetooth, orientation, the volume buttons, the screen and its frame rate, touch, and
// the haptics. Written to test the iOS 16.5 port to the Redmi K40, where some of these come through the port's own
// shims and some do not come at all; on an iPhone it is an ordinary application. One table, a row each, whose visible
// cells get new text ten times a second (the table is never reloaded). Everything starts when the tab comes to the
// front and stops when it goes away or the application goes to the background, and nothing is used before it has said
// it is there: a missing sensor or a refused permission is a row that says so.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreHaptics/CoreHaptics.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <sys/sysctl.h>
#import "check.h"

/*
 * The light sensor has no public API. It is a HID service, and the HID event system's client -- what backboardd and
 * CoreBrightness read it with -- is in IOKit: the SDK's IOKit.tbd exports it, but there is no header for it. So what
 * is used of it is declared here, the way Apple's own IOHIDFamily-1915 (iOS 16.5's) calls it in
 * HID/HIDEventSystemClient.m and tools/IOHIDEventSystemMonitor.c. The numbers are its IOHIDEventTypes.h and
 * IOHIDEventFieldDefs.h: a field is its event's type << 16 | its index.
 */
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef void (*IOHIDEventCallback)(void *target, void *refcon, IOHIDServiceClientRef sender, IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator, int type,
    CFDictionaryRef attributes);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef client, IOHIDEventCallback callback,
    void *target, void *refcon);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef loop, CFStringRef mode);
extern void IOHIDEventSystemClientUnscheduleWithRunLoop(IOHIDEventSystemClientRef client, CFRunLoopRef loop,
    CFStringRef mode);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef service, CFStringRef key, CFTypeRef value);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, IOHIDEventRef matching,
    uint32_t options);
extern uint32_t IOHIDEventGetType(IOHIDEventRef event);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, uint32_t field);
extern CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef event, uint32_t field);

#define HID_PAGE_APPLE_VENDOR           0xff00
#define HID_USAGE_LIGHT                 4                               /* the ambient light sensor, on that page */
#define HID_EVENT_LIGHT                 12                              /* kIOHIDEventTypeAmbientLightSensor */
#define HID_FIELD_LIGHT_LEVEL           (HID_EVENT_LIGHT << 16 | 0)     /* ...SensorLevel: whole lux, an integer */
#define HID_FIELD_LIGHT_ILLUMINANCE     (HID_EVENT_LIGHT << 16 | 11)    /* ...SensorIlluminance: lux, a double */
#define HID_CLIENT_MONITOR              1                               /* kIOHIDEventSystemClientTypeMonitor */
#define HID_CLIENT_PASSIVE              2                               /* ...Passive: gets no events, may ask */

/* the rows, in the order they are shown */
enum {
	R_LIGHT, R_BRIGHTNESS,
	R_PROXIMITY,
	R_ACCELEROMETER, R_GYROSCOPE, R_MAGNETOMETER, R_DEVICE_MOTION,
	R_BAROMETER,
	R_PEDOMETER, R_ACTIVITY,
	R_HEADING,
	R_LOCATION,
	R_BATTERY, R_THERMAL, R_LOW_POWER,
	R_MICROPHONE,
	R_CAMERAS, R_CAMERA_ACCESS,
	R_BLUETOOTH,
	R_ORIENTATION,
	R_VOLUME,
	R_DISPLAY, R_FRAME_RATE,
	R_TOUCH, R_TOUCH_PAD,
	R_HAPTICS, R_HAPTIC_BUTTONS,
	R_COUNT
};

static NSString *const row_names[R_COUNT] = {
	[R_LIGHT] = @"Ambient light", [R_BRIGHTNESS] = @"Screen brightness", [R_PROXIMITY] = @"Proximity",
	[R_ACCELEROMETER] = @"Accelerometer", [R_GYROSCOPE] = @"Gyroscope", [R_MAGNETOMETER] = @"Magnetometer (raw)",
	[R_DEVICE_MOTION] = @"Device motion", [R_BAROMETER] = @"Barometer", [R_PEDOMETER] = @"Pedometer",
	[R_ACTIVITY] = @"Motion activity", [R_HEADING] = @"Compass heading", [R_LOCATION] = @"Location",
	[R_BATTERY] = @"Battery", [R_THERMAL] = @"Thermal state", [R_LOW_POWER] = @"Low Power Mode",
	[R_MICROPHONE] = @"Microphone", [R_CAMERAS] = @"Cameras", [R_CAMERA_ACCESS] = @"Camera permission",
	[R_BLUETOOTH] = @"Bluetooth", [R_ORIENTATION] = @"Device orientation", [R_VOLUME] = @"Volume buttons",
	[R_DISPLAY] = @"Display", [R_FRAME_RATE] = @"Frame rate", [R_TOUCH] = @"Touch", [R_TOUCH_PAD] = @"",
	[R_HAPTICS] = @"Haptics", [R_HAPTIC_BUTTONS] = @"",
};

/* the sections: a title, the rows from first on, and a footer that says where the values come from */
static const struct section {
	__unsafe_unretained NSString *title, *footer;
	int first, count;
} sections[] = {
	{ @"Light", @"IOHIDEventSystemClient (private, in IOKit): services of Apple's vendor page 0xff00, usage 4; their "
	    "events (type 12: Illuminance and Level) as they come, else IOHIDServiceClientCopyEvent. An app without "
	    "com.apple.private.hid.client.event-monitor sees no such service. Fallback, on the K40 port only: sysctl "
	    "kern.hakios.als_millilux. Brightness: UIScreen.brightness.", R_LIGHT, 2 },
	{ @"Proximity", @"UIDevice.proximityMonitoringEnabled (it reads back NO where there is no sensor), proximityState, "
	    "UIDeviceProximityStateDidChangeNotification. Near turns the screen off.", R_PROXIMITY, 1 },
	{ @"Motion", @"CMMotionManager: isAccelerometerAvailable, isGyroAvailable, isMagnetometerAvailable, "
	    "isDeviceMotionAvailable; each started at 50 Hz and read here ten times a second.", R_ACCELEROMETER, 4 },
	{ @"Barometer", @"CMAltimeter: isRelativeAltitudeAvailable, startRelativeAltitudeUpdatesToQueue (pressure, and the "
	    "altitude since it started).", R_BAROMETER, 1 },
	{ @"Steps and activity", @"CMPedometer: isStepCountingAvailable, startPedometerUpdatesFromDate (since launch). "
	    "CMMotionActivityManager: isActivityAvailable, startActivityUpdatesToQueue.", R_PEDOMETER, 2 },
	{ @"Compass", @"CLLocationManager: headingAvailable, startUpdatingHeading. The true heading needs a location.",
	    R_HEADING, 1 },
	{ @"Location", @"CLLocationManager: requestWhenInUseAuthorization, startUpdatingLocation, authorizationStatus, "
	    "accuracyAuthorization.", R_LOCATION, 1 },
	{ @"Battery and power", @"UIDevice: batteryMonitoringEnabled, batteryLevel, batteryState. NSProcessInfo: "
	    "thermalState, lowPowerModeEnabled.", R_BATTERY, 3 },
	{ @"Microphone", @"AVAudioSession.recordPermission; AVAudioRecorder with metering on, into a temporary file that is "
	    "emptied every 30 s and deleted when it stops.", R_MICROPHONE, 1 },
	{ @"Cameras", @"AVCaptureDeviceDiscoverySession over every built-in camera type and position (no picture is "
	    "taken); AVCaptureDevice authorizationStatusForMediaType.", R_CAMERAS, 2 },
	{ @"Bluetooth", @"CBCentralManager.state and CBManager.authorization (nothing is scanned for).", R_BLUETOOTH, 1 },
	{ @"Orientation", @"UIDevice beginGeneratingDeviceOrientationNotifications, orientation: the device's, not this "
	    "portrait-only interface's.", R_ORIENTATION, 1 },
	{ @"Volume buttons", @"AVAudioSession.outputVolume, observed (KVO) while the session is active.", R_VOLUME, 1 },
	{ @"Screen", @"UIScreen: maximumFramesPerSecond, nativeBounds, nativeScale. A CADisplayLink asking for the maximum "
	    "(preferredFrameRateRange) counts its frames.", R_DISPLAY, 2 },
	{ @"Touch", @"UITouch on a view with multipleTouchEnabled; the force where traitCollection.forceTouchCapability "
	    "says there is 3D Touch.", R_TOUCH, 2 },
	{ @"Haptics", @"CHHapticEngine.capabilitiesForHardware; UIImpactFeedbackGenerator, UINotificationFeedbackGenerator, "
	    "AudioServicesPlaySystemSound(kSystemSoundID_Vibrate).", R_HAPTICS, 2 },
};
#define SECTION_COUNT ((NSInteger)(sizeof(sections) / sizeof(sections[0])))

enum { S_NONE, S_WAITING, S_AVAILABLE, S_MISSING, S_DENIED };

static NSString *const status_text[] = {
	[S_NONE] = @"", [S_WAITING] = @"waiting for data", [S_AVAILABLE] = @"available",
	[S_MISSING] = @"not available on this device", [S_DENIED] = @"no permission",
};

static UIColor *
status_color(int status)
{
	switch (status) {
	case S_AVAILABLE:
		return UIColor.systemGreenColor;
	case S_WAITING:
		return UIColor.systemBlueColor;
	case S_DENIED:
		return UIColor.systemOrangeColor;
	default:
		return UIColor.secondaryLabelColor;
	}
}

/* CMAuthorizationStatus, AVAuthorizationStatus and CBManagerAuthorization number the same four answers alike */
static NSString *
permission_name(NSInteger permission)
{
	switch (permission) {
	case 0:
		return @"not asked yet";
	case 1:
		return @"restricted";
	case 2:
		return @"denied";
	case 3:
		return @"allowed";
	default:
		return @"?";
	}
}

static BOOL
permission_refused(NSInteger permission)
{
	return permission == 1 || permission == 2;
}

/* an error of Core Motion's that means the user (or the system) said no */
static BOOL
motion_refused(NSError *error)
{
	return [error.domain isEqualToString:CMErrorDomain] && (error.code == CMErrorMotionActivityNotAuthorized ||
	    error.code == CMErrorMotionActivityNotEntitled || error.code == CMErrorNotAuthorized ||
	    error.code == CMErrorNotEntitled);
}

static NSString *
orientation_name(UIDeviceOrientation orientation)
{
	switch (orientation) {
	case UIDeviceOrientationPortrait:
		return @"portrait";
	case UIDeviceOrientationPortraitUpsideDown:
		return @"upside down";
	case UIDeviceOrientationLandscapeLeft:
		return @"landscape left";
	case UIDeviceOrientationLandscapeRight:
		return @"landscape right";
	case UIDeviceOrientationFaceUp:
		return @"face up";
	case UIDeviceOrientationFaceDown:
		return @"face down";
	default:
		return @"unknown";
	}
}

static NSString *
bluetooth_name(CBManagerState state)
{
	switch (state) {
	case CBManagerStateResetting:
		return @"resetting";
	case CBManagerStateUnsupported:
		return @"unsupported";
	case CBManagerStateUnauthorized:
		return @"unauthorized";
	case CBManagerStatePoweredOff:
		return @"powered off";
	case CBManagerStatePoweredOn:
		return @"powered on";
	default:
		return @"unknown";
	}
}

static NSString *
location_permission_name(CLAuthorizationStatus status)
{
	switch (status) {
	case kCLAuthorizationStatusNotDetermined:
		return @"not asked yet";
	case kCLAuthorizationStatusRestricted:
		return @"restricted";
	case kCLAuthorizationStatusDenied:
		return @"denied";
	case kCLAuthorizationStatusAuthorizedAlways:
		return @"always";
	case kCLAuthorizationStatusAuthorizedWhenInUse:
		return @"when in use";
	default:
		return @"?";
	}
}

static NSString *
field_accuracy_name(CMMagneticFieldCalibrationAccuracy accuracy)
{
	switch (accuracy) {
	case CMMagneticFieldCalibrationAccuracyLow:
		return @"low";
	case CMMagneticFieldCalibrationAccuracyMedium:
		return @"medium";
	case CMMagneticFieldCalibrationAccuracyHigh:
		return @"high";
	default:
		return @"uncalibrated";
	}
}

static NSString *
frame_name(CMAttitudeReferenceFrame frame)
{
	switch (frame) {
	case CMAttitudeReferenceFrameXMagneticNorthZVertical:
		return @"x magnetic north, z vertical";
	case CMAttitudeReferenceFrameXArbitraryCorrectedZVertical:
		return @"x arbitrary (corrected), z vertical";
	default:
		return @"x arbitrary, z vertical";
	}
}

/* the hardware's own name for itself: on the K40 port, the iPhone it says it is */
static NSString *
machine(void)
{
	char name[64] = "";
	size_t size = sizeof(name) - 1;

	return sysctlbyname("hw.machine", name, &size, NULL, 0) == 0 ? @(name) : @"?";
}

/* The pad touches are counted on: as many fingers as the screen reports, each drawn where it is. */
@interface TouchPad : UIView
@property (weak, nonatomic) UIScrollView *scroller;
@property (readonly, nonatomic) NSUInteger down, most;
@property (readonly, nonatomic) CGFloat force, forceMax;
@end

@implementation TouchPad {
	NSMutableSet<UITouch *> *_touches;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_touches = [NSMutableSet new];
		self.multipleTouchEnabled = YES;
		self.backgroundColor = UIColor.tertiarySystemFillColor;
		self.layer.cornerRadius = 10;
		self.clipsToBounds = YES;
		self.contentMode = UIViewContentModeRedraw;
	}
	return self;
}

- (void)changed
{
	BOOL pressure = self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable;

	_down = _touches.count;
	_most = MAX(_most, _down);
	_force = 0;
	for (UITouch *touch in _touches) {
		if (pressure) {
			_force = MAX(_force, touch.force);
			_forceMax = touch.maximumPossibleForce;
		}
	}
	/* (no scrolling while a finger is on the pad, or a slow one would be taken for a scroll and cancelled) */
	self.scroller.scrollEnabled = _down == 0;
	[self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[_touches unionSet:touches];
	[self changed];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self changed];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[_touches minusSet:touches];
	[self changed];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[_touches minusSet:touches];
	[self changed];
}

- (void)drawRect:(CGRect)rect
{
	if (_touches.count == 0) {
		NSString *hint = @"touch here, with as many fingers as you like";
		NSDictionary *look = @{ NSFontAttributeName: [UIFont systemFontOfSize:13],
		    NSForegroundColorAttributeName: UIColor.secondaryLabelColor };
		CGSize size = [hint sizeWithAttributes:look];

		[hint drawAtPoint:CGPointMake((self.bounds.size.width - size.width) / 2, (self.bounds.size.height - size.height) / 2)
		    withAttributes:look];
		return;
	}
	[[UIColor.systemTealColor colorWithAlphaComponent:0.6] setFill];
	for (UITouch *touch in _touches) {
		CGPoint p = [touch locationInView:self];

		[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x - 22, p.y - 22, 44, 44)] fill];
	}
}

@end

/* A row: its name and status on one line, the value (as many lines as it has) under them. */
@interface SensorCell : UITableViewCell
@property (strong, nonatomic) UILabel *name, *status, *value;
@end

@implementation SensorCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
{
	UILayoutGuide *margins;
	NSLayoutConstraint *under;

	self = [super initWithStyle:style reuseIdentifier:identifier];
	if (self == nil) {
		return nil;
	}
	self.selectionStyle = UITableViewCellSelectionStyleNone;
	_name = [UILabel new];
	_name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
	_status = [UILabel new];
	_status.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
	_status.textAlignment = NSTextAlignmentRight;
	_status.numberOfLines = 2;
	_value = [UILabel new];
	/* (monospaced, so that numbers changing ten times a second do not make the line jump; 11.5 points: the longest
	   lines, about 44 characters, fit on one line of a 375-point screen) */
	_value.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
	_value.numberOfLines = 0;
	for (UILabel *label in @[ _name, _status, _value ]) {
		label.translatesAutoresizingMaskIntoConstraints = NO;
		[self.contentView addSubview:label];
	}
	[_name setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	[_name setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	margins = self.contentView.layoutMarginsGuide;
	under = [_value.topAnchor constraintEqualToAnchor:_name.bottomAnchor constant:4];
	under.priority = UILayoutPriorityDefaultLow;
	[NSLayoutConstraint activateConstraints:@[
		[_name.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[_name.topAnchor constraintEqualToAnchor:margins.topAnchor],
		[_status.leadingAnchor constraintGreaterThanOrEqualToAnchor:_name.trailingAnchor constant:8],
		[_status.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[_status.firstBaselineAnchor constraintEqualToAnchor:_name.firstBaselineAnchor],
		[_value.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[_value.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[_value.topAnchor constraintGreaterThanOrEqualToAnchor:_name.bottomAnchor constant:4],
		[_value.topAnchor constraintGreaterThanOrEqualToAnchor:_status.bottomAnchor constant:2],
		under,
		[_value.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
	]];
	return self;
}

@end

@interface SensorController : UITableViewController <CLLocationManagerDelegate, CBCentralManagerDelegate>
- (void)light:(IOHIDEventRef)event polled:(BOOL)polled;
- (void)row:(int)row status:(int)status text:(NSString *)format, ... NS_FORMAT_FUNCTION(3, 4);
@end

/* the HID event system's callback, on the main run loop (the client is scheduled there) */
static void
light_event(void *target, __unused void *refcon, __unused IOHIDServiceClientRef sender, IOHIDEventRef event)
{
	if (event != NULL && IOHIDEventGetType(event) == HID_EVENT_LIGHT) {
		[(__bridge SensorController *)target light:event polled:NO];
	}
}

static void *volume_context = &volume_context;

@implementation SensorController {
	NSString *_value[R_COUNT];
	int _status[R_COUNT];
	BOOL _appeared, _running;
	NSTimer *_timer;
	unsigned _ticks;
	NSDate *_launched;

	/* the light: the HID client, and the last reading it gave */
	IOHIDEventSystemClientRef _hid;
	NSString *_hidKind;
	CFIndex _hidServices, _hidServicesAsked;
	unsigned _hidEvents, _hidPolls;
	double _lux, _illuminance;
	CFIndex _level;
	CFTimeInterval _luxWhen, _luxEventWhen;
	BOOL _luxPolled;

	BOOL _proximity;
	unsigned _proximityChanges, _orientationChanges;

	CMMotionManager *_motion;
	CMAttitudeReferenceFrame _frame;
	CMAltimeter *_altimeter;
	CMAltitudeData *_altitude;
	NSError *_altitudeError;
	CMPedometer *_pedometer;
	CMPedometerData *_steps;
	NSError *_stepsError;
	CMMotionActivityManager *_activity;
	CMMotionActivity *_lastActivity;
	NSInteger _altimeterPermission, _pedometerPermission, _activityPermission;

	CLLocationManager *_location;
	CLLocation *_place;
	CLHeading *_heading;
	NSError *_locationError, *_headingError;
	BOOL _locationServicesOff;

	/* the audio session: the microphone's meter and the volume */
	BOOL _sessionActive, _observingVolume, _inputAvailable;
	AVAudioSessionRecordPermission _recordPermission;
	AVAudioRecorder *_recorder;
	NSString *_audioProblem, *_inputName;
	float _volume, _peakMax;
	unsigned _volumeChanges;

	NSString *_cameraList;
	NSUInteger _cameraCount;
	NSInteger _cameraPermission;

	CBCentralManager *_bluetooth;
	NSInteger _bluetoothPermission;

	CADisplayLink *_link;
	CFTimeInterval _windowStart;
	unsigned _frames;
	double _fps;

	TouchPad *_pad;
	UITableViewCell *_padCell, *_buttonsCell;
	id<CHHapticDeviceCapability> _haptics;
	NSArray<UIImpactFeedbackGenerator *> *_impacts;
	UINotificationFeedbackGenerator *_notification;
	NSString *_lastHaptic;
}

- (void)viewDidLoad
{
	NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
	NSDictionary *info = NSBundle.mainBundle.infoDictionary;
	UILabel *header = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 34)];

	[super viewDidLoad];
	self.navigationItem.title = @"Sensor Check";
	_launched = [NSDate date];
	_volume = -1;
	_peakMax = -160;
	_lastHaptic = @"none yet";
	for (int r = 0; r < R_COUNT; r++) {
		_value[r] = @"-";
		_status[r] = S_WAITING;
	}
	_status[R_TOUCH_PAD] = _status[R_HAPTIC_BUTTONS] = S_NONE;

	[self.tableView registerClass:SensorCell.class forCellReuseIdentifier:@"sensor"];
	self.tableView.rowHeight = UITableViewAutomaticDimension;
	self.tableView.estimatedRowHeight = 64;
	self.tableView.allowsSelection = NO;
	/* (touches reach the pad at once, before the table has decided whether they are a scroll) */
	self.tableView.delaysContentTouches = NO;
	header.text = [NSString stringWithFormat:@"%@ · iOS %@ · System Check %@ (%@)", machine(),
	    UIDevice.currentDevice.systemVersion, info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]];
	header.font = [UIFont systemFontOfSize:12];
	header.textColor = UIColor.secondaryLabelColor;
	header.textAlignment = NSTextAlignmentCenter;
	self.tableView.tableHeaderView = header;
	[self makePad];
	[self makeButtons];

	_haptics = CHHapticEngine.capabilitiesForHardware;
	_impacts = @[ [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight],
	    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium],
	    [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy] ];
	_notification = [UINotificationFeedbackGenerator new];

	[center addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
	[center addObserver:self selector:@selector(foreground:) name:UIApplicationWillEnterForegroundNotification object:nil];
	[center addObserver:self selector:@selector(proximityChanged:) name:UIDeviceProximityStateDidChangeNotification
	    object:nil];
	[center addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification
	    object:nil];
}

- (void)makePad
{
	_padCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	_padCell.selectionStyle = UITableViewCellSelectionStyleNone;
	_pad = [TouchPad new];
	_pad.scroller = self.tableView;
	_pad.translatesAutoresizingMaskIntoConstraints = NO;
	[_padCell.contentView addSubview:_pad];
	[NSLayoutConstraint activateConstraints:@[
		[_pad.leadingAnchor constraintEqualToAnchor:_padCell.contentView.layoutMarginsGuide.leadingAnchor],
		[_pad.trailingAnchor constraintEqualToAnchor:_padCell.contentView.layoutMarginsGuide.trailingAnchor],
		[_pad.topAnchor constraintEqualToAnchor:_padCell.contentView.layoutMarginsGuide.topAnchor],
		[_pad.bottomAnchor constraintEqualToAnchor:_padCell.contentView.layoutMarginsGuide.bottomAnchor],
		/* (room for a whole hand: about 40 % of a phone's height) */
		[_pad.heightAnchor constraintEqualToConstant:340],
	]];
}

- (void)makeButtons
{
	NSArray *titles = @[ @"Light", @"Medium", @"Heavy", @"Success", @"Vibrate" ];
	UIStackView *row = [UIStackView new];

	_buttonsCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	_buttonsCell.selectionStyle = UITableViewCellSelectionStyleNone;
	row.axis = UILayoutConstraintAxisHorizontal;
	row.distribution = UIStackViewDistributionFillEqually;
	row.spacing = 6;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	for (NSUInteger i = 0; i < titles.count; i++) {
		UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];

		[button setTitle:titles[i] forState:UIControlStateNormal];
		button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
		button.titleLabel.adjustsFontSizeToFitWidth = YES;
		button.backgroundColor = UIColor.tertiarySystemFillColor;
		button.layer.cornerRadius = 8;
		button.tag = (NSInteger)i;
		[button addTarget:self action:@selector(haptic:) forControlEvents:UIControlEventTouchUpInside];
		[row addArrangedSubview:button];
	}
	[_buttonsCell.contentView addSubview:row];
	[NSLayoutConstraint activateConstraints:@[
		[row.leadingAnchor constraintEqualToAnchor:_buttonsCell.contentView.layoutMarginsGuide.leadingAnchor],
		[row.trailingAnchor constraintEqualToAnchor:_buttonsCell.contentView.layoutMarginsGuide.trailingAnchor],
		[row.topAnchor constraintEqualToAnchor:_buttonsCell.contentView.layoutMarginsGuide.topAnchor],
		[row.bottomAnchor constraintEqualToAnchor:_buttonsCell.contentView.layoutMarginsGuide.bottomAnchor],
		[row.heightAnchor constraintEqualToConstant:38],
	]];
}

- (void)haptic:(UIButton *)button
{
	switch (button.tag) {
	case 0:
	case 1:
	case 2:
		[_impacts[(NSUInteger)button.tag] impactOccurred];
		break;
	case 3:
		[_notification notificationOccurred:UINotificationFeedbackTypeSuccess];
		break;
	default:
		AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
		break;
	}
	_lastHaptic = [button titleForState:UIControlStateNormal];
}

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	_appeared = YES;
	[self start];
}

/* (another tab: everything stops, the proximity sensor with it, which would otherwise turn the screen off) */
- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	_appeared = NO;
	[self stop];
}

- (void)background:(NSNotification *)notification
{
	[self stop];
}

- (void)foreground:(NSNotification *)notification
{
	if (_appeared) {
		[self start];
	}
}

- (void)proximityChanged:(NSNotification *)notification
{
	_proximityChanges++;
}

- (void)orientationChanged:(NSNotification *)notification
{
	_orientationChanges++;
}

#pragma mark starting and stopping

- (void)start
{
	UIDevice *device = UIDevice.currentDevice;

	if (_running) {
		return;
	}
	_running = YES;
	[self startLight];
	/* (the one way to know whether there is a proximity sensor: it stays NO where there is none) */
	device.proximityMonitoringEnabled = YES;
	_proximity = device.proximityMonitoringEnabled;
	[device beginGeneratingDeviceOrientationNotifications];
	device.batteryMonitoringEnabled = YES;
	[self startMotion];
	[self startLocation];
	[self startAudio];
	[self startCameras];
	_bluetooth = [[CBCentralManager alloc] initWithDelegate:self queue:nil
	    options:@{ CBCentralManagerOptionShowPowerAlertKey: @NO }];
	[self startDisplayLink];
	_timer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
	/* (common modes: the values keep changing while the table scrolls) */
	[NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
	[self tick];
}

- (void)stop
{
	UIDevice *device = UIDevice.currentDevice;

	if (!_running) {
		return;
	}
	_running = NO;
	[_timer invalidate];
	_timer = nil;
	[_link invalidate];
	_link = nil;
	[self stopLight];
	device.proximityMonitoringEnabled = NO;
	[device endGeneratingDeviceOrientationNotifications];
	device.batteryMonitoringEnabled = NO;
	[_motion stopAccelerometerUpdates];
	[_motion stopGyroUpdates];
	[_motion stopMagnetometerUpdates];
	[_motion stopDeviceMotionUpdates];
	[_altimeter stopRelativeAltitudeUpdates];
	_altimeter = nil;
	[_pedometer stopPedometerUpdates];
	_pedometer = nil;
	[_activity stopActivityUpdates];
	_activity = nil;
	[_location stopUpdatingLocation];
	[_location stopUpdatingHeading];
	[self stopAudio];
	_bluetooth.delegate = nil;
	_bluetooth = nil;
}

/*
 * The light: a client of the HID event system that matches only the ambient light sensor's services. Which client:
 * IOHIDEventSystemClientCreate's (the kind that gets events), and if the system refuses that, a monitor, and last a
 * passive one, which gets no events but may still ask a service for its current one. All of it on the main thread:
 * the calls are quick, and the client then needs no lock.
 */
- (void)startLight
{
	NSDictionary *matching = @{ @"PrimaryUsagePage": @(HID_PAGE_APPLE_VENDOR), @"PrimaryUsage": @(HID_USAGE_LIGHT) };

	if (_hid != NULL) {
		return;
	}
	_hidKind = @"default";
	_hid = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
	if (_hid == NULL) {
		_hidKind = @"monitor";
		_hid = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, HID_CLIENT_MONITOR, NULL);
	}
	if (_hid == NULL) {
		_hidKind = @"passive";
		_hid = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, HID_CLIENT_PASSIVE, NULL);
	}
	if (_hid == NULL) {
		_hidKind = nil;
		return;
	}
	_hidServices = _hidServicesAsked = 0;
	IOHIDEventSystemClientSetMatching(_hid, (__bridge CFDictionaryRef)matching);
	/* (the callback before the schedule: once scheduled, events may come) */
	IOHIDEventSystemClientRegisterEventCallback(_hid, light_event, (__bridge void *)self, NULL);
	IOHIDEventSystemClientScheduleWithRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
}

- (void)stopLight
{
	if (_hid == NULL) {
		return;
	}
	/* (taken off the run loop before it is let go: no callback may come for a client that is gone) */
	IOHIDEventSystemClientUnscheduleWithRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
	CFRelease(_hid);
	_hid = NULL;
}

/*
 * Every tick: the services the client has (they come after it is made, not with it), and, if no event has come for a
 * second, each one asked for its current event. A rate-controlled client gets events only once it has asked for a
 * rate, so each new service is told the interval wanted, ReportInterval in microseconds: ten a second.
 */
- (void)pollLight
{
	CFArrayRef services;
	CFIndex count;

	if (_hid == NULL) {
		return;
	}
	services = IOHIDEventSystemClientCopyServices(_hid);
	count = services != NULL ? CFArrayGetCount(services) : 0;
	if (count != _hidServicesAsked) {
		for (CFIndex i = 0; i < count; i++) {
			IOHIDServiceClientSetProperty((IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i), CFSTR("ReportInterval"),
			    (__bridge CFNumberRef)@100000);
		}
		_hidServicesAsked = count;
	}
	_hidServices = count;
	if (CACurrentMediaTime() - _luxEventWhen > 1.0) {
		for (CFIndex i = 0; i < count; i++) {
			IOHIDEventRef event = IOHIDServiceClientCopyEvent((IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i),
			    HID_EVENT_LIGHT, NULL, 0);

			if (event != NULL) {
				if (IOHIDEventGetType(event) == HID_EVENT_LIGHT) {
					[self light:event polled:YES];
				}
				CFRelease(event);
				break;
			}
		}
	}
	if (services != NULL) {
		CFRelease(services);
	}
}

/* An ambient light event: the illuminance (a double) where the sensor gives it, otherwise its whole-lux level. */
- (void)light:(IOHIDEventRef)event polled:(BOOL)polled
{
	_illuminance = IOHIDEventGetFloatValue(event, HID_FIELD_LIGHT_ILLUMINANCE);
	_level = IOHIDEventGetIntegerValue(event, HID_FIELD_LIGHT_LEVEL);
	_lux = _illuminance > 0 ? _illuminance : (double)_level;
	_luxWhen = CACurrentMediaTime();
	_luxPolled = polled;
	if (polled) {
		_hidPolls++;
	} else {
		_hidEvents++;
		_luxEventWhen = _luxWhen;
	}
}

- (void)startMotion
{
	CMAttitudeReferenceFrame frames = CMMotionManager.availableAttitudeReferenceFrames;
	__weak SensorController *weak = self;

	if (_motion == nil) {
		_motion = [CMMotionManager new];
	}
	_motion.accelerometerUpdateInterval = 0.02;
	_motion.gyroUpdateInterval = 0.02;
	_motion.magnetometerUpdateInterval = 0.02;
	_motion.deviceMotionUpdateInterval = 0.02;
	if (_motion.accelerometerAvailable) {
		[_motion startAccelerometerUpdates];
	}
	if (_motion.gyroAvailable) {
		[_motion startGyroUpdates];
	}
	if (_motion.magnetometerAvailable) {
		[_motion startMagnetometerUpdates];
	}
	if (_motion.deviceMotionAvailable) {
		/* the frame that uses the most there is: magnetic north also gives the heading and a calibrated field */
		_frame = (frames & CMAttitudeReferenceFrameXMagneticNorthZVertical) ? CMAttitudeReferenceFrameXMagneticNorthZVertical :
		    (frames & CMAttitudeReferenceFrameXArbitraryCorrectedZVertical) ? CMAttitudeReferenceFrameXArbitraryCorrectedZVertical :
		    CMAttitudeReferenceFrameXArbitraryZVertical;
		[_motion startDeviceMotionUpdatesUsingReferenceFrame:_frame];
	}

	if (CMAltimeter.isRelativeAltitudeAvailable) {
		_altimeter = [CMAltimeter new];
		[_altimeter startRelativeAltitudeUpdatesToQueue:NSOperationQueue.mainQueue
		    withHandler:^(CMAltitudeData *data, NSError *error) {
			SensorController *me = weak;

			if (me != nil) {
				me->_altitude = data ?: me->_altitude;
				me->_altitudeError = error;
			}
		}];
	}
	if (CMPedometer.isStepCountingAvailable) {
		_pedometer = [CMPedometer new];
		/* (from the launch, again after each return to the front: the pedometer counts the steps in between too) */
		[_pedometer startPedometerUpdatesFromDate:_launched withHandler:^(CMPedometerData *data, NSError *error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				SensorController *me = weak;

				if (me != nil) {
					me->_steps = data ?: me->_steps;
					me->_stepsError = error;
				}
			});
		}];
	}
	if (CMMotionActivityManager.isActivityAvailable) {
		_activity = [CMMotionActivityManager new];
		[_activity startActivityUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMMotionActivity *activity) {
			SensorController *me = weak;

			if (me != nil && activity != nil) {
				me->_lastActivity = activity;
			}
		}];
	}
}

- (void)startLocation
{
	__weak SensorController *weak = self;

	if (_location == nil) {
		_location = [CLLocationManager new];
		_location.delegate = self;
		_location.desiredAccuracy = kCLLocationAccuracyBest;
		_location.headingFilter = kCLHeadingFilterNone;
	}
	if (_location.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
		[_location requestWhenInUseAuthorization];
	}
	/* (started before it is allowed: it begins once it is) */
	[_location startUpdatingLocation];
	if (CLLocationManager.headingAvailable) {
		[_location startUpdatingHeading];
	}
	/* (whether Location Services are on at all: asked off the main thread, where it may wait for locationd) */
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		BOOL on = CLLocationManager.locationServicesEnabled;

		dispatch_async(dispatch_get_main_queue(), ^{
			SensorController *me = weak;

			if (me != nil) {
				me->_locationServicesOff = !on;
			}
		});
	});
}

/*
 * One audio session for the microphone and the volume. Recording needs PlayAndRecord (mixed with other audio, to the
 * speaker, and with haptics allowed: iOS silences them while recording otherwise); without the microphone, Ambient is
 * enough for the volume to be observed. The volume is outputVolume, which changes when a volume button is pressed.
 */
- (void)startAudio
{
	AVAudioSession *session = AVAudioSession.sharedInstance;
	AVAudioSessionRecordPermission permission = session.recordPermission;
	__weak SensorController *weak = self;
	NSError *error = nil;
	BOOL ok;

	_audioProblem = nil;
	_recordPermission = permission;
	_inputAvailable = session.inputAvailable;
	if (permission == AVAudioSessionRecordPermissionGranted && _inputAvailable) {
		ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
		    withOptions:AVAudioSessionCategoryOptionMixWithOthers | AVAudioSessionCategoryOptionDefaultToSpeaker error:&error];
		[session setAllowHapticsAndSystemSoundsDuringRecording:YES error:nil];
	} else {
		ok = [session setCategory:AVAudioSessionCategoryAmbient error:&error];
	}
	_sessionActive = ok && [session setActive:YES error:&error];
	if (!_sessionActive) {
		_audioProblem = error.localizedDescription ?: @"the audio session would not start";
	}
	if (!_observingVolume) {
		[session addObserver:self forKeyPath:@"outputVolume"
		    options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:volume_context];
		_observingVolume = YES;
	}
	if (permission == AVAudioSessionRecordPermissionGranted && _inputAvailable && _sessionActive) {
		[self startRecorder];
	} else if (permission == AVAudioSessionRecordPermissionUndetermined) {
		[session requestRecordPermission:^(BOOL granted) {
			dispatch_async(dispatch_get_main_queue(), ^{
				SensorController *me = weak;

				/* (allowed: the session again, now able to record) */
				if (me != nil && me->_running && granted) {
					[me stopAudio];
					[me startAudio];
				}
			});
		}];
	}
}

/* 16 kHz, 16 bits, one channel: 32 KB a second at most, and the file is emptied every 30 s (see tick) */
- (void)startRecorder
{
	NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"meter.caf"]];
	NSDictionary *settings = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @16000.0,
	    AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO,
	    AVLinearPCMIsBigEndianKey: @NO };
	NSError *error = nil;

	_recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
	_recorder.meteringEnabled = YES;
	if (_recorder == nil || ![_recorder record]) {
		_audioProblem = error.localizedDescription ?: @"AVAudioRecorder would not record";
		_recorder = nil;
	}
	_peakMax = -160;
}

- (void)stopAudio
{
	AVAudioSession *session = AVAudioSession.sharedInstance;

	if (_recorder != nil) {
		[_recorder stop];
		[_recorder deleteRecording];
		_recorder = nil;
	}
	if (_observingVolume) {
		[session removeObserver:self forKeyPath:@"outputVolume" context:volume_context];
		_observingVolume = NO;
	}
	if (_sessionActive) {
		[session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
		_sessionActive = NO;
	}
}

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context != volume_context) {
		[super observeValueForKeyPath:path ofObject:object change:change context:context];
		return;
	}
	/* (KVO may tell on another thread) */
	dispatch_async(dispatch_get_main_queue(), ^{
		float volume = AVAudioSession.sharedInstance.outputVolume;

		if (self->_volume >= 0 && volume != self->_volume) {
			self->_volumeChanges++;
		}
		self->_volume = volume;
	});
}

/*
 * The cameras are listed once (they do not change), off the main thread: the discovery asks the media server, which
 * on a port may be slow to answer. Asking for the permission shows whether the system's prompt for it works.
 */
- (void)startCameras
{
	__weak SensorController *weak = self;

	if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusNotDetermined) {
		[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
		}];
	}
	if (_cameraList != nil) {
		return;
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray arrayWithArray:@[
			AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera,
			AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInDualCamera,
			AVCaptureDeviceTypeBuiltInDualWideCamera, AVCaptureDeviceTypeBuiltInTripleCamera,
			AVCaptureDeviceTypeBuiltInTrueDepthCamera ]];
		AVCaptureDeviceDiscoverySession *discovery;
		NSMutableString *list = [NSMutableString string];
		NSUInteger count = 0;

		/*
		 * (the LiDAR camera's type is iOS 15.4's: an iOS that does not know it would throw. It is asked by version, not
		 * with @available, which needs compiler-rt's __isPlatformVersionAtLeast, and named by its value -- the type
		 * constants' values are their names -- so that nothing weak is referred to)
		 */
		if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){ 15, 4, 0 }]) {
			[types addObject:@"AVCaptureDeviceTypeBuiltInLiDARDepthCamera"];
		}
		discovery = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:AVMediaTypeVideo
		    position:AVCaptureDevicePositionUnspecified];
		for (AVCaptureDevice *camera in discovery.devices) {
			NSString *position = camera.position == AVCaptureDevicePositionBack ? @"back" :
			    camera.position == AVCaptureDevicePositionFront ? @"front" : @"other";

			[list appendFormat:@"%@%@ · %@ · %@", count++ > 0 ? @"\n" : @"", position,
			    [camera.deviceType stringByReplacingOccurrencesOfString:@"AVCaptureDeviceTypeBuiltIn" withString:@""],
			    camera.localizedName];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			SensorController *me = weak;

			if (me != nil) {
				me->_cameraList = list;
				me->_cameraCount = count;
			}
		});
	});
}

/* the frame rate: a display link asking for the screen's most, its frames counted over each second */
- (void)startDisplayLink
{
	float most = (float)UIScreen.mainScreen.maximumFramesPerSecond;

	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
	_link.preferredFrameRateRange = CAFrameRateRangeMake(most, most, most);
	[_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	_windowStart = 0;
	_frames = 0;
}

- (void)frame:(CADisplayLink *)link
{
	if (_windowStart == 0) {
		_windowStart = link.timestamp;
		_frames = 0;
		return;
	}
	_frames++;
	if (link.timestamp - _windowStart >= 1.0) {
		_fps = _frames / (link.timestamp - _windowStart);
		_windowStart = link.timestamp;
		_frames = 0;
	}
}

#pragma mark delegates

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations
{
	_place = locations.lastObject ?: _place;
	_locationError = nil;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)heading
{
	_heading = heading;
	_headingError = nil;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error
{
	if (error.code == kCLErrorHeadingFailure) {
		_headingError = error;
	} else {
		_locationError = error;
	}
}

/* (no calibration figure over the table: an uncalibrated heading shows as such) */
- (BOOL)locationManagerShouldDisplayHeadingCalibration:(CLLocationManager *)manager
{
	return NO;
}

/* (its state is read every tick) */
- (void)centralManagerDidUpdateState:(CBCentralManager *)central
{
}

#pragma mark the rows

- (void)row:(int)row status:(int)status text:(NSString *)format, ...
{
	va_list arguments;

	va_start(arguments, format);
	_value[row] = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	_status[row] = status;
}

- (void)describeLight
{
	int milli = -1, readings = 0;
	size_t size = sizeof(milli);
	BOOL port = sysctlbyname("kern.hakios.als_millilux", &milli, &size, NULL, 0) == 0;
	NSString *hid, *sysctl;
	float brightness = UIScreen.mainScreen.brightness;

	if (port) {
		size = sizeof(readings);
		(void)sysctlbyname("kern.hakios.als_events", &readings, &size, NULL, 0);
	}
	hid = _hidKind == nil ? @"HID: no event system client" :
	    [NSString stringWithFormat:@"HID %@: %ld service%s, %u events, %u polls", _hidKind, (long)_hidServices,
	    _hidServices == 1 ? "" : "s", _hidEvents, _hidPolls];
	sysctl = !port ? @"port sysctl: none (not the K40 port)" : milli < 0 ? @"port sysctl: no reading yet" :
	    [NSString stringWithFormat:@"port sysctl: %d mlx, %d readings", milli, readings];
	if (_luxWhen > 0 && CACurrentMediaTime() - _luxWhen < 5) {
		[self row:R_LIGHT status:S_AVAILABLE text:@"%9.2f lx  (%@)\nilluminance %.2f, level %ld\n%@\n%@", _lux,
		    _luxPolled ? @"HID copyEvent" : @"HID event", _illuminance, (long)_level, hid, sysctl];
	} else if (port && milli >= 0) {
		[self row:R_LIGHT status:S_AVAILABLE text:@"%9.2f lx  (port sysctl, fallback)\n"
		    "kern.hakios.als_millilux: K40 port only\n%@\n%@", milli / 1000.0, hid, sysctl];
	} else if (_hidServices > 0 || port) {
		[self row:R_LIGHT status:S_WAITING text:@"        - lx\na light sensor is there, no reading yet\n%@\n%@", hid,
		    sysctl];
	} else {
		[self row:R_LIGHT status:S_MISSING text:@"        - lx\nno light service seen (it needs the HID "
		    "event-monitor entitlement)\n%@\n%@", hid, sysctl];
	}
	[self row:R_BRIGHTNESS status:S_AVAILABLE text:@"%.3f (%.0f %%)", brightness, brightness * 100];
}

- (void)describeMotion
{
	CMAccelerometerData *a = _motion.accelerometerData;
	CMGyroData *g = _motion.gyroData;
	CMMagnetometerData *m = _motion.magnetometerData;
	CMDeviceMotion *d = _motion.deviceMotion;
	CMMotionActivity *now = _lastActivity;

	if (!_motion.accelerometerAvailable) {
		[self row:R_ACCELEROMETER status:S_MISSING text:@"isAccelerometerAvailable: NO"];
	} else if (a == nil) {
		[self row:R_ACCELEROMETER status:S_WAITING text:@"x -  y -  z -  g"];
	} else {
		[self row:R_ACCELEROMETER status:S_AVAILABLE text:@"x %+.3f  y %+.3f  z %+.3f  g", a.acceleration.x,
		    a.acceleration.y, a.acceleration.z];
	}
	if (!_motion.gyroAvailable) {
		[self row:R_GYROSCOPE status:S_MISSING text:@"isGyroAvailable: NO"];
	} else if (g == nil) {
		[self row:R_GYROSCOPE status:S_WAITING text:@"x -  y -  z -  rad/s"];
	} else {
		[self row:R_GYROSCOPE status:S_AVAILABLE text:@"x %+.3f  y %+.3f  z %+.3f  rad/s", g.rotationRate.x,
		    g.rotationRate.y, g.rotationRate.z];
	}
	if (!_motion.magnetometerAvailable) {
		[self row:R_MAGNETOMETER status:S_MISSING text:@"isMagnetometerAvailable: NO"];
	} else if (m == nil) {
		[self row:R_MAGNETOMETER status:S_WAITING text:@"x -  y -  z -  µT"];
	} else {
		[self row:R_MAGNETOMETER status:S_AVAILABLE text:@"x %+7.1f  y %+7.1f  z %+7.1f  µT", m.magneticField.x,
		    m.magneticField.y, m.magneticField.z];
	}
	if (!_motion.deviceMotionAvailable) {
		[self row:R_DEVICE_MOTION status:S_MISSING text:@"isDeviceMotionAvailable: NO"];
	} else if (d == nil) {
		[self row:R_DEVICE_MOTION status:S_WAITING text:@"frame: %@", frame_name(_frame)];
	} else {
		[self row:R_DEVICE_MOTION status:S_AVAILABLE text:@"frame: %@\n"
		    "roll %+6.1f°  pitch %+6.1f°  yaw %+6.1f°\n"
		    "gravity  x %+.3f y %+.3f z %+.3f g\n"
		    "user     x %+.3f y %+.3f z %+.3f g\n"
		    "rotation x %+.3f y %+.3f z %+.3f rad/s\n"
		    "field  x %+7.1f y %+7.1f z %+7.1f µT\n"
		    "field accuracy: %@, heading %@",
		    frame_name(_frame), d.attitude.roll * 180 / M_PI, d.attitude.pitch * 180 / M_PI, d.attitude.yaw * 180 / M_PI,
		    d.gravity.x, d.gravity.y, d.gravity.z, d.userAcceleration.x, d.userAcceleration.y, d.userAcceleration.z,
		    d.rotationRate.x, d.rotationRate.y, d.rotationRate.z, d.magneticField.field.x, d.magneticField.field.y,
		    d.magneticField.field.z, field_accuracy_name(d.magneticField.accuracy),
		    d.heading >= 0 && _frame == CMAttitudeReferenceFrameXMagneticNorthZVertical ?
		    [NSString stringWithFormat:@"%.1f°", d.heading] : @"-"];
	}

	if (!CMAltimeter.isRelativeAltitudeAvailable) {
		[self row:R_BAROMETER status:S_MISSING text:@"isRelativeAltitudeAvailable: NO"];
	} else if (permission_refused(_altimeterPermission) || motion_refused(_altitudeError)) {
		[self row:R_BAROMETER status:S_DENIED text:@"Motion & Fitness: %@", permission_name(_altimeterPermission)];
	} else if (_altitude == nil) {
		[self row:R_BAROMETER status:S_WAITING text:@"pressure - kPa\nrelative altitude - m%@",
		    _altitudeError ? [@"\n" stringByAppendingString:_altitudeError.localizedDescription] : @""];
	} else {
		[self row:R_BAROMETER status:S_AVAILABLE text:@"pressure %.3f kPa (%.1f hPa)\nrelative altitude %+.2f m",
		    _altitude.pressure.doubleValue, _altitude.pressure.doubleValue * 10, _altitude.relativeAltitude.doubleValue];
	}

	if (!CMPedometer.isStepCountingAvailable) {
		[self row:R_PEDOMETER status:S_MISSING text:@"isStepCountingAvailable: NO"];
	} else if (permission_refused(_pedometerPermission) || motion_refused(_stepsError)) {
		[self row:R_PEDOMETER status:S_DENIED text:@"Motion & Fitness: %@", permission_name(_pedometerPermission)];
	} else if (_steps == nil) {
		[self row:R_PEDOMETER status:S_WAITING text:@"- steps since launch (walk a few)\ndistance -, floors -"];
	} else {
		[self row:R_PEDOMETER status:S_AVAILABLE text:@"%@ steps since launch\ndistance %@, floors up %@ down %@",
		    _steps.numberOfSteps, _steps.distance ? [NSString stringWithFormat:@"%.1f m", _steps.distance.doubleValue] : @"-",
		    (id)_steps.floorsAscended ?: @"-", (id)_steps.floorsDescended ?: @"-"];
	}

	if (!CMMotionActivityManager.isActivityAvailable) {
		[self row:R_ACTIVITY status:S_MISSING text:@"isActivityAvailable: NO"];
	} else if (permission_refused(_activityPermission)) {
		[self row:R_ACTIVITY status:S_DENIED text:@"Motion & Fitness: %@", permission_name(_activityPermission)];
	} else if (now == nil) {
		[self row:R_ACTIVITY status:S_WAITING text:@"-"];
	} else {
		NSMutableArray *what = [NSMutableArray array];

		if (now.stationary) {
			[what addObject:@"stationary"];
		}
		if (now.walking) {
			[what addObject:@"walking"];
		}
		if (now.running) {
			[what addObject:@"running"];
		}
		if (now.automotive) {
			[what addObject:@"automotive"];
		}
		if (now.cycling) {
			[what addObject:@"cycling"];
		}
		if (what.count == 0) {
			[what addObject:@"unknown"];
		}
		[self row:R_ACTIVITY status:S_AVAILABLE text:@"%@, confidence %@", [what componentsJoinedByString:@" + "],
		    now.confidence == CMMotionActivityConfidenceHigh ? @"high" :
		    now.confidence == CMMotionActivityConfidenceMedium ? @"medium" : @"low"];
	}
}

- (void)describeLocation
{
	CLAuthorizationStatus permission = _location.authorizationStatus;
	BOOL refused = permission == kCLAuthorizationStatusDenied || permission == kCLAuthorizationStatusRestricted ||
	    ([_locationError.domain isEqualToString:kCLErrorDomain] && _locationError.code == kCLErrorDenied);
	NSString *who = [NSString stringWithFormat:@"authorization: %@%@", location_permission_name(permission),
	    permission == kCLAuthorizationStatusAuthorizedWhenInUse || permission == kCLAuthorizationStatusAuthorizedAlways ?
	    (_location.accuracyAuthorization == CLAccuracyAuthorizationFullAccuracy ? @", full accuracy" :
	    @", reduced accuracy") : @""];
	CLLocation *p = _place;

	if (!CLLocationManager.headingAvailable) {
		[self row:R_HEADING status:S_MISSING text:@"headingAvailable: NO"];
	} else if (_heading == nil) {
		[self row:R_HEADING status:S_WAITING text:@"magnetic -  true -\naccuracy -%@",
		    _headingError ? @" (the heading failed)" : @""];
	} else {
		[self row:R_HEADING status:S_AVAILABLE text:@"magnetic %5.1f°  true %@\naccuracy %@", _heading.magneticHeading,
		    _heading.trueHeading >= 0 ? [NSString stringWithFormat:@"%5.1f°", _heading.trueHeading] : @"- (no location)",
		    _heading.headingAccuracy >= 0 ? [NSString stringWithFormat:@"±%.1f°", _heading.headingAccuracy] :
		    @"none (uncalibrated)"];
	}

	if (_locationServicesOff) {
		[self row:R_LOCATION status:S_DENIED text:@"Location Services are off\n%@", who];
	} else if (refused) {
		[self row:R_LOCATION status:S_DENIED text:@"%@", who];
	} else if (p == nil) {
		[self row:R_LOCATION status:S_WAITING text:@"no fix yet%@\n%@",
		    _locationError ? [@": " stringByAppendingString:_locationError.localizedDescription] : @"", who];
	} else {
		[self row:R_LOCATION status:S_AVAILABLE text:@"lat %+.6f  lon %+.6f\n±%.0f m, %.0f s old\n"
		    "altitude %.1f m ±%.0f, speed %@\n%@", p.coordinate.latitude, p.coordinate.longitude, p.horizontalAccuracy,
		    -p.timestamp.timeIntervalSinceNow, p.altitude, p.verticalAccuracy,
		    p.speed >= 0 ? [NSString stringWithFormat:@"%.1f m/s", p.speed] : @"-", who];
	}
}

- (void)describeDevice
{
	UIDevice *device = UIDevice.currentDevice;
	NSProcessInfo *process = NSProcessInfo.processInfo;
	UIScreen *screen = UIScreen.mainScreen;
	BOOL pressure = self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable;
	float level = device.batteryLevel;
	NSString *state, *thermal;

	if (!_proximity) {
		[self row:R_PROXIMITY status:S_MISSING text:@"proximityMonitoringEnabled read back NO"];
	} else {
		/* (a sensor the system only says it has stays far with no changes: hence the count) */
		[self row:R_PROXIMITY status:S_AVAILABLE text:@"%@, %u changes (cover the top of the screen)",
		    device.proximityState ? @"near" : @"far", _proximityChanges];
	}

	switch (device.batteryState) {
	case UIDeviceBatteryStateUnplugged:
		state = @"unplugged";
		break;
	case UIDeviceBatteryStateCharging:
		state = @"charging";
		break;
	case UIDeviceBatteryStateFull:
		state = @"full";
		break;
	default:
		state = @"state unknown";
		break;
	}
	if (level < 0) {
		[self row:R_BATTERY status:S_MISSING text:@"batteryLevel -1, %@", state];
	} else {
		[self row:R_BATTERY status:S_AVAILABLE text:@"%.0f %%, %@", level * 100, state];
	}
	switch (process.thermalState) {
	case NSProcessInfoThermalStateNominal:
		thermal = @"nominal";
		break;
	case NSProcessInfoThermalStateFair:
		thermal = @"fair";
		break;
	case NSProcessInfoThermalStateSerious:
		thermal = @"serious";
		break;
	default:
		thermal = @"critical";
		break;
	}
	[self row:R_THERMAL status:S_AVAILABLE text:@"%@", thermal];
	[self row:R_LOW_POWER status:S_AVAILABLE text:@"%@", process.lowPowerModeEnabled ? @"on" : @"off"];

	[self row:R_ORIENTATION status:device.orientation == UIDeviceOrientationUnknown ? S_WAITING : S_AVAILABLE
	    text:@"%@, %u changes", orientation_name(device.orientation), _orientationChanges];

	[self row:R_DISPLAY status:S_AVAILABLE text:@"max %ld fps · %.0f×%.0f px\nscale %.0f, native %.3f · %.0f×%.0f pt",
	    (long)screen.maximumFramesPerSecond, screen.nativeBounds.size.width, screen.nativeBounds.size.height,
	    screen.scale, screen.nativeScale, screen.bounds.size.width, screen.bounds.size.height];
	if (_fps <= 0) {
		[self row:R_FRAME_RATE status:S_WAITING text:@"counting (asked for %ld)", (long)screen.maximumFramesPerSecond];
	} else {
		[self row:R_FRAME_RATE status:S_AVAILABLE text:@"%.1f fps measured (asked for %ld)", _fps,
		    (long)screen.maximumFramesPerSecond];
	}

	[self row:R_TOUCH status:_pad.most > 0 ? S_AVAILABLE : S_WAITING text:@"%lu on the pad now, %lu at most\n%@",
	    (unsigned long)_pad.down, (unsigned long)_pad.most,
	    !pressure ? @"3D Touch: not on this device" : _pad.forceMax > 0 ?
	    [NSString stringWithFormat:@"force %.2f of %.2f", _pad.force, _pad.forceMax] : @"3D Touch: yes, press harder"];
	[self row:R_HAPTICS status:_haptics.supportsHaptics ? S_AVAILABLE : S_MISSING
	    text:@"Core Haptics: %@, audio %@\nlast fired: %@", _haptics.supportsHaptics ? @"yes" : @"no",
	    _haptics.supportsAudio ? @"yes" : @"no", _lastHaptic];
}

- (void)describeAudioAndRadios
{
	CBManagerState bluetooth = _bluetooth.state;

	if (!_inputAvailable) {
		[self row:R_MICROPHONE status:S_MISSING text:@"AVAudioSession.inputAvailable: NO"];
	} else if (_recordPermission == AVAudioSessionRecordPermissionDenied) {
		[self row:R_MICROPHONE status:S_DENIED text:@"recordPermission: denied"];
	} else if (_recordPermission == AVAudioSessionRecordPermissionUndetermined) {
		[self row:R_MICROPHONE status:S_WAITING text:@"asking for the permission"];
	} else if (_recorder == nil) {
		[self row:R_MICROPHONE status:S_MISSING text:@"%@", _audioProblem ?: @"not recording"];
	} else {
		float average = [_recorder averagePowerForChannel:0], peak = [_recorder peakPowerForChannel:0];

		_peakMax = MAX(_peakMax, peak);
		[self row:R_MICROPHONE status:S_AVAILABLE text:@"average %6.1f dBFS, peak %6.1f\nloudest %6.1f dBFS · %@",
		    average, peak, _peakMax, _inputName ?: @"?"];
	}

	if (!_observingVolume || !_sessionActive) {
		[self row:R_VOLUME status:S_MISSING text:@"%@", _audioProblem ?: @"the audio session is not active"];
	} else if (_volume < 0) {
		[self row:R_VOLUME status:S_WAITING text:@"-"];
	} else {
		[self row:R_VOLUME status:S_AVAILABLE text:@"%.4f (%.0f %%), %u changes\npress a volume button", _volume,
		    _volume * 100, _volumeChanges];
	}

	if (_cameraList == nil) {
		[self row:R_CAMERAS status:S_WAITING text:@"looking"];
	} else if (_cameraCount == 0) {
		[self row:R_CAMERAS status:S_MISSING text:@"the discovery session found none"];
	} else {
		[self row:R_CAMERAS status:S_AVAILABLE text:@"%@", _cameraList];
	}
	[self row:R_CAMERA_ACCESS status:_cameraPermission == 3 ? S_AVAILABLE : permission_refused(_cameraPermission) ?
	    S_DENIED : S_WAITING text:@"%@", permission_name(_cameraPermission)];

	[self row:R_BLUETOOTH status:_bluetooth == nil || bluetooth == CBManagerStateUnknown ||
	    bluetooth == CBManagerStateResetting ? S_WAITING : bluetooth == CBManagerStateUnsupported ? S_MISSING :
	    bluetooth == CBManagerStateUnauthorized ? S_DENIED : S_AVAILABLE
	    text:@"%@, authorization: %@", bluetooth_name(bluetooth), permission_name(_bluetoothPermission)];
}

/* what may ask another process, once a second rather than ten times */
- (void)slowTick
{
	AVAudioSession *session = AVAudioSession.sharedInstance;

	_recordPermission = session.recordPermission;
	_inputAvailable = session.inputAvailable;
	_inputName = session.currentRoute.inputs.firstObject.portName;
	_altimeterPermission = CMAltimeter.authorizationStatus;
	_pedometerPermission = CMPedometer.authorizationStatus;
	_activityPermission = CMMotionActivityManager.authorizationStatus;
	_cameraPermission = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
	_bluetoothPermission = CBManager.authorization;
}

- (void)tick
{
	if (_ticks++ % 10 == 0) {
		[self slowTick];
	}
	[self pollLight];
	if (_recorder != nil) {
		[_recorder updateMeters];
		/* (record after stop starts the file again from nothing) */
		if (_recorder.currentTime > 30) {
			[_recorder stop];
			[_recorder record];
		}
	}
	[self describeLight];
	[self describeMotion];
	[self describeLocation];
	[self describeDevice];
	[self describeAudioAndRadios];
	[self show];
}

/* A visible cell's labels, given the row's text; YES if that changed how tall it has to be. */
- (BOOL)fill:(SensorCell *)cell row:(int)row
{
	NSString *status = status_text[_status[row]];
	BOOL taller = NO;

	if (![cell.value.text isEqualToString:_value[row]]) {
		cell.value.text = _value[row];
		if (cell.value.bounds.size.width > 0) {
			CGFloat height = [cell.value sizeThatFits:CGSizeMake(cell.value.bounds.size.width, CGFLOAT_MAX)].height;

			taller = fabs(height - cell.value.bounds.size.height) >= 1;
		}
	}
	if (![cell.status.text isEqualToString:status]) {
		cell.status.text = status;
		cell.status.textColor = status_color(_status[row]);
		taller = YES;
	}
	return taller;
}

/* the new text into the cells on the screen; the table only asked again for heights when one has to change */
- (void)show
{
	BOOL resize = NO;

	for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
		UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];

		if ([cell isKindOfClass:SensorCell.class]) {
			resize |= [self fill:(SensorCell *)cell row:sections[path.section].first + (int)path.row];
		}
	}
	if (resize) {
		[UIView performWithoutAnimation:^{
			[self.tableView beginUpdates];
			[self.tableView endUpdates];
		}];
	}
}

#pragma mark the table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table
{
	return SECTION_COUNT;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section
{
	return sections[section].count;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section
{
	return sections[section].title;
}

- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section
{
	return sections[section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path
{
	int row = sections[path.section].first + (int)path.row;
	SensorCell *cell;

	if (row == R_TOUCH_PAD) {
		return _padCell;
	}
	if (row == R_HAPTIC_BUTTONS) {
		return _buttonsCell;
	}
	cell = [table dequeueReusableCellWithIdentifier:@"sensor" forIndexPath:path];
	cell.name.text = row_names[row];
	[self fill:cell row:row];
	return cell;
}

@end

UIViewController *
sensor_controller(void)
{
	return [[SensorController alloc] initWithStyle:UITableViewStyleInsetGrouped];
}
