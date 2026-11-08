// System Check's Motion tab (what was Motion Test): what CoreMotion gives an application, live -- a phone in 3D that
// turns as this one does (the device motion's attitude, from where it was when the tab came to the front or at the
// last tap on it), and below the numbers: the accelerometer, the gyroscope and the device motion (attitude, gravity,
// rotation rate, user acceleration, heading). Written for the iOS 16.5 port to the Redmi K40, where all of it comes
// from the phone's sensor DSP. The 3D is Core Animation's: six layers in a CATransformLayer, their backs culled -- a
// box is convex, so that is all the hiding it needs. The sensors run only while the tab is on the screen.
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import "check.h"

/* the model, in points: a phone of the K40's proportions (75.4 x 163.7 x 7.8 mm), a little thicker to be seen */
#define MODEL_W 120.0
#define MODEL_H 260.0
#define MODEL_D 18.0

typedef struct { double m[3][3]; } mat3;

/* the rotation a unit quaternion makes (column vectors: p' = M p); CoreMotion's turns the device into the reference */
static mat3
mat_of(CMQuaternion q)
{
	mat3 r = { { { 1 - 2 * (q.y * q.y + q.z * q.z), 2 * (q.x * q.y - q.z * q.w), 2 * (q.x * q.z + q.y * q.w) },
	             { 2 * (q.x * q.y + q.z * q.w), 1 - 2 * (q.x * q.x + q.z * q.z), 2 * (q.y * q.z - q.x * q.w) },
	             { 2 * (q.x * q.z - q.y * q.w), 2 * (q.y * q.z + q.x * q.w), 1 - 2 * (q.x * q.x + q.y * q.y) } } };
	return r;
}

static mat3
mul(mat3 a, mat3 b)
{
	mat3 r;

	for (int i = 0; i < 3; i++) {
		for (int j = 0; j < 3; j++) {
			r.m[i][j] = a.m[i][0] * b.m[0][j] + a.m[i][1] * b.m[1][j] + a.m[i][2] * b.m[2][j];
		}
	}
	return r;
}

static mat3
transpose(mat3 a)
{
	mat3 r;

	for (int i = 0; i < 3; i++) {
		for (int j = 0; j < 3; j++) {
			r.m[i][j] = a.m[j][i];
		}
	}
	return r;
}

/* Core Animation's rows-times-matrix convention: the transpose's numbers */
static CATransform3D
transform_of(mat3 n)
{
	CATransform3D t = CATransform3DIdentity;

	t.m11 = n.m[0][0], t.m12 = n.m[1][0], t.m13 = n.m[2][0];
	t.m21 = n.m[0][1], t.m22 = n.m[1][1], t.m23 = n.m[2][1];
	t.m31 = n.m[0][2], t.m32 = n.m[1][2], t.m33 = n.m[2][2];
	return t;
}

@interface MotionController : UIViewController
@property (strong) CMMotionManager *motion;
@property (strong) NSTimer *timer;
@property (strong) UILabel *label, *hint;
@property (strong) UIView *stage;
@property (strong) CATransformLayer *phone;
@property (assign) BOOL haveStart;
@property (assign) CMQuaternion start;
@property (assign) unsigned ticks;
@end

@implementation MotionController

- (CALayer *)face:(CGSize)size color:(UIColor *)color transform:(CATransform3D)t
{
	CALayer *l = [CALayer layer];

	l.bounds = CGRectMake(0, 0, size.width, size.height);
	l.position = CGPointZero;
	l.backgroundColor = color.CGColor;
	l.borderColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
	l.borderWidth = 1;
	l.doubleSided = NO;
	l.transform = t;
	l.edgeAntialiasingMask = kCALayerLeftEdge | kCALayerRightEdge | kCALayerTopEdge | kCALayerBottomEdge;
	[self.phone addSublayer:l];
	return l;
}

- (void)buildPhone
{
	CALayer *front, *back, *lens, *notch;
	CATextLayer *name;

	self.phone = [CATransformLayer layer];
	self.phone.position = CGPointMake(self.stage.bounds.size.width / 2, self.stage.bounds.size.height / 2);
	[self.stage.layer addSublayer:self.phone];
	/* (the parent's perspective: things nearer are bigger) */
	CATransform3D p = CATransform3DIdentity;
	p.m34 = -1.0 / 700;
	self.stage.layer.sublayerTransform = p;

	/* the screen side (toward the viewer at the start), the back with its camera, and the four edges */
	front = [self face:CGSizeMake(MODEL_W, MODEL_H) color:[UIColor colorWithRed:0.08 green:0.10 blue:0.16 alpha:1]
	    transform:CATransform3DMakeTranslation(0, 0, MODEL_D / 2)];
	front.cornerRadius = 14;
	notch = [CALayer layer];
	notch.frame = CGRectMake(MODEL_W / 2 - 4, 8, 8, 8);
	notch.cornerRadius = 4;
	notch.backgroundColor = UIColor.blackColor.CGColor;
	[front addSublayer:notch];
	name = [CATextLayer layer];
	name.frame = CGRectMake(0, MODEL_H / 2 - 22, MODEL_W, 44);
	name.string = @"K40";
	name.fontSize = 30;
	name.alignmentMode = kCAAlignmentCenter;
	name.foregroundColor = [UIColor colorWithRed:0.45 green:0.75 blue:1 alpha:1].CGColor;
	name.contentsScale = UIScreen.mainScreen.scale;
	[front addSublayer:name];

	back = [self face:CGSizeMake(MODEL_W, MODEL_H) color:[UIColor colorWithRed:0.20 green:0.45 blue:0.85 alpha:1]
	    transform:CATransform3DTranslate(CATransform3DMakeRotation(M_PI, 0, 1, 0), 0, 0, MODEL_D / 2)];
	back.cornerRadius = 14;
	lens = [CALayer layer];
	lens.frame = CGRectMake(12, 12, 34, 52);        /* (the K40's cameras: top left, seen from behind) */
	lens.cornerRadius = 10;
	lens.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1].CGColor;
	[back addSublayer:lens];

	UIColor *edge = [UIColor colorWithWhite:0.72 alpha:1];
	[self face:CGSizeMake(MODEL_D, MODEL_H) color:edge
	    transform:CATransform3DTranslate(CATransform3DMakeRotation(M_PI / 2, 0, 1, 0), 0, 0, MODEL_W / 2)];
	[self face:CGSizeMake(MODEL_D, MODEL_H) color:edge
	    transform:CATransform3DTranslate(CATransform3DMakeRotation(-M_PI / 2, 0, 1, 0), 0, 0, MODEL_W / 2)];
	[self face:CGSizeMake(MODEL_W, MODEL_D) color:[UIColor colorWithWhite:0.82 alpha:1]
	    transform:CATransform3DTranslate(CATransform3DMakeRotation(M_PI / 2, 1, 0, 0), 0, 0, MODEL_H / 2)];
	[self face:CGSizeMake(MODEL_W, MODEL_D) color:[UIColor colorWithWhite:0.60 alpha:1]
	    transform:CATransform3DTranslate(CATransform3DMakeRotation(-M_PI / 2, 1, 0, 0), 0, 0, MODEL_H / 2)];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	self.stage = [UIView new];
	self.stage.backgroundColor = UIColor.secondarySystemBackgroundColor;
	[self.view addSubview:self.stage];
	[self.stage addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(restart)]];
	self.hint = [UILabel new];
	self.hint.text = @"turns as this phone does — tap: facing you again";
	self.hint.font = [UIFont systemFontOfSize:12];
	self.hint.textColor = UIColor.secondaryLabelColor;
	self.hint.textAlignment = NSTextAlignmentCenter;
	[self.stage addSubview:self.hint];

	self.label = [UILabel new];
	self.label.numberOfLines = 0;
	/* (10.5: the longest line, about 52 characters, on one line of a 375-point screen; at 12 its z wrapped) */
	self.label.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
	[self.view addSubview:self.label];
	self.motion = [CMMotionManager new];
	self.motion.accelerometerUpdateInterval = 0.02;
	self.motion.gyroUpdateInterval = 0.02;
	self.motion.deviceMotionUpdateInterval = 0.02;
}

/* the stage under the status bar, 46% of the screen high; the numbers below it, down to the tab bar */
- (void)viewDidLayoutSubviews
{
	CGRect all = self.view.bounds;
	UIEdgeInsets safe = self.view.safeAreaInsets;
	CGFloat top = MAX(safe.top, 20) + 6;

	[super viewDidLayoutSubviews];
	self.stage.frame = CGRectMake(0, top, all.size.width, all.size.height * 0.46);
	self.hint.frame = CGRectMake(0, self.stage.bounds.size.height - 22, all.size.width, 18);
	/* (ten lines high at most, from the top: a label taller than its text would centre it) */
	self.label.frame = CGRectMake(16, CGRectGetMaxY(self.stage.frame) + 12, all.size.width - 32,
	    MIN(ceil(self.label.font.lineHeight * 10) + 4,
	    all.size.height - safe.bottom - CGRectGetMaxY(self.stage.frame) - 18));
	if (self.phone == nil) {
		[self buildPhone];
	}
	self.phone.position = CGPointMake(self.stage.bounds.size.width / 2, self.stage.bounds.size.height / 2);
}

/* the sensors only while the tab is on the screen; the model faces the viewer again each time it comes back */
- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	self.haveStart = NO;
	[self.motion startAccelerometerUpdates];
	[self.motion startGyroUpdates];
	[self.motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXMagneticNorthZVertical];
	self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 target:self selector:@selector(tick) userInfo:nil
	    repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	[self.timer invalidate];
	self.timer = nil;
	[self.motion stopAccelerometerUpdates];
	[self.motion stopGyroUpdates];
	[self.motion stopDeviceMotionUpdates];
}

- (void)restart
{
	self.haveStart = NO;
}

/*
 * The model in the start's device frame (x right, y up, z out of the screen), seen straight on: at the start (and
 * after a tap) its screen faces the viewer, as this phone's does. What it shows is the rotation from the start's
 * attitude to this one, R(start)^T R(now), both turning the device into the reference. Core Animation's y goes
 * down, hence Q = diag(1, -1, 1) on both sides.
 */
- (void)tick
{
	CMDeviceMotion *m = self.motion.deviceMotion;

	if (m != nil) {
		CMQuaternion q = m.attitude.quaternion;
		mat3 flip = { { { 1, 0, 0 }, { 0, -1, 0 }, { 0, 0, 1 } } }, relative;

		if (!self.haveStart) {
			self.start = q;
			self.haveStart = YES;
		}
		relative = mul(transpose(mat_of(self.start)), mat_of(q));
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		self.phone.transform = transform_of(mul(flip, mul(relative, flip)));
		[CATransaction commit];
	}
	if (self.ticks++ % 3 == 0) {
		[self show];
	}
}

- (void)show
{
	CMAcceleration a = self.motion.accelerometerData.acceleration;
	CMRotationRate g = self.motion.gyroData.rotationRate;
	CMDeviceMotion *m = self.motion.deviceMotion;
	CMAttitude *t = m.attitude;
	NSString *text = [NSString stringWithFormat:
	    @"available: accel %d gyro %d motion %d\n"
	    @"accelerometer (g)      x %+.3f  y %+.3f  z %+.3f\n"
	    @"gyroscope (rad/s)      x %+.3f  y %+.3f  z %+.3f\n"
	    @"attitude (deg)         roll %+6.1f  pitch %+6.1f  yaw %+6.1f\n"
	    @"gravity (g)            %+.2f %+.2f %+.2f\n"
	    @"rotation rate (rad/s)  %+.2f %+.2f %+.2f\n"
	    @"user acceleration (g)  %+.2f %+.2f %+.2f\n"
	    @"heading %.1f, field accuracy %d",
	    self.motion.accelerometerAvailable, self.motion.gyroAvailable, self.motion.deviceMotionAvailable,
	    a.x, a.y, a.z, g.x, g.y, g.z,
	    t.roll * 180 / M_PI, t.pitch * 180 / M_PI, t.yaw * 180 / M_PI,
	    m.gravity.x, m.gravity.y, m.gravity.z, m.rotationRate.x, m.rotationRate.y, m.rotationRate.z,
	    m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z, m.heading, (int)m.magneticField.accuracy];

	self.label.text = text;
}

@end

UIViewController *
motion_controller(void)
{
	return [MotionController new];
}
