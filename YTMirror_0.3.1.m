#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static char StateKey;
static char ButtonKey;
static char HostKey;
static char ControlsVisibleKey;
static Class PlayerClass;
static Class ControlsClass;

@interface YTMirrorTransform : NSObject
@property CATransform3D original;
@property CATransform3D applied;
@end
@implementation YTMirrorTransform
@end

@interface YTMirrorState : NSObject
@property BOOL enabled;
@property (nonatomic, strong) NSMapTable<CALayer *, YTMirrorTransform *> *transforms;
@end
@implementation YTMirrorState
@end

static void SetSurfaceTransform(CALayer *surface, CATransform3D transform) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    surface.transform = transform;
    [CATransaction commit];
}

static void CollectRenderers(UIView *view, NSMutableArray<CALayer *> *layers) {
    if ([view isKindOfClass:ControlsClass] ||
        [NSStringFromClass(view.class) isEqualToString:@"YTMainAppVideoPlayerOverlayView"]) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL renderer = [name isEqualToString:@"MLHAMSBDLSampleBufferRenderingView"] ||
                    [name isEqualToString:@"MLHAMIOSurfaceMainThreadRenderingView"];
    if (renderer && !CGRectIsEmpty(view.bounds)) {
        [layers addObject:view.layer];
        return;
    }
    for (UIView *child in view.subviews) CollectRenderers(child, layers);
}

static NSArray<CALayer *> *VideoRenderers(UIView *player) {
    NSMutableArray<CALayer *> *layers = [NSMutableArray array];
    for (UIView *container in player.subviews) CollectRenderers(container, layers);
    return layers;
}

static void UpdateRenderers(YTMirrorState *state, NSArray<CALayer *> *renderers) {
    for (CALayer *layer in state.transforms.keyEnumerator.allObjects) {
        if ([renderers containsObject:layer]) continue;
        YTMirrorTransform *transform = [state.transforms objectForKey:layer];
        if (CATransform3DEqualToTransform(layer.transform, transform.applied)) {
            SetSurfaceTransform(layer, transform.original);
        }
        [state.transforms removeObjectForKey:layer];
    }

    for (CALayer *layer in renderers) {
        CATransform3D current = layer.transform;
        YTMirrorTransform *transform = [state.transforms objectForKey:layer];
        if (!transform) {
            transform = [YTMirrorTransform new];
            transform.original = current;
            [state.transforms setObject:transform forKey:layer];
        } else if (!CATransform3DEqualToTransform(current, transform.applied)) {
            transform.original = current;
        }

        CATransform3D reflection = CATransform3DMakeScale(-1, 1, 1);
        reflection.m41 = (1 - 2 * layer.anchorPoint.x) * CGRectGetWidth(layer.bounds);
        transform.applied = CATransform3DConcat(reflection, transform.original);
        if (!CATransform3DEqualToTransform(current, transform.applied)) {
            SetSurfaceTransform(layer, transform.applied);
        }
    }
}

static UIView *FindPlayer(UIView *view) {
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:PlayerClass]) return ancestor;
    }
    return nil;
}

static void SetButtonIcon(UIButton *button, UIColor *color) {
    static char IconColorKey;
    UIColor *current = objc_getAssociatedObject(button, &IconColorKey);
    if ([current isEqual:color]) return;

    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightMedium];
    UIImage *icon = [UIImage systemImageNamed:@"arrow.left.and.right" withConfiguration:configuration];
    [button setPreferredSymbolConfiguration:configuration forImageInState:UIControlStateNormal];
    [button setImage:[icon imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal]
            forState:UIControlStateNormal];
    objc_setAssociatedObject(button, &IconColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SetButtonState(UIButton *button, BOOL enabled) {
    SetButtonIcon(button, enabled ? UIColor.systemYellowColor : UIColor.whiteColor);
    button.accessibilityValue = enabled ? @"已开启" : @"已关闭";
}

@interface YTMirrorButtonTarget : NSObject
- (void)toggleMirror:(UIButton *)button;
- (void)keepControlsVisible:(UIButton *)button;
@end

@implementation YTMirrorButtonTarget
- (void)keepControlsVisible:(UIButton *)button {
    Class controller = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    SEL reset = NSSelectorFromString(@"resetAutoHideTimer");
    for (UIResponder *responder = button.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:controller] && [responder respondsToSelector:reset]) {
            ((void (*)(id, SEL))objc_msgSend)(responder, reset);
            return;
        }
    }
}

- (void)toggleMirror:(UIButton *)button {
    UIView *player = FindPlayer(button);
    if (!player) return;

    YTMirrorState *state = objc_getAssociatedObject(player, &StateKey);
    if (state.enabled) {
        state.enabled = NO;
        UpdateRenderers(state, @[]);
        SetButtonState(button, NO);
        return;
    }
    NSArray<CALayer *> *renderers = VideoRenderers(player);
    if (renderers.count == 0) {
        SetButtonIcon(button, UIColor.systemRedColor);
        button.accessibilityValue = @"未找到视频渲染视图";
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"当前视频画面暂不可镜像");
        return;
    }
    if (!state) {
        state = [YTMirrorState new];
        state.transforms = [NSMapTable weakToStrongObjectsMapTable];
        objc_setAssociatedObject(player, &StateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state.enabled = YES;
    UpdateRenderers(state, renderers);
    SetButtonState(button, YES);
}
@end

static BOOL ControlsAreVisible(UIView *controls) {
    for (UIView *view = controls; view; view = view.superview) {
        NSNumber *state = objc_getAssociatedObject(view, &ControlsVisibleKey);
        if (state) return state.boolValue;
    }
    return YES;
}

static void SetHostVisible(UIView *host, BOOL visible) {
    if (!host) return;
    CGFloat opacity = visible ? 1 : 0;
    host.userInteractionEnabled = visible;
    host.accessibilityElementsHidden = !visible;
    if (host.alpha == opacity) return;

    NSTimeInterval duration = UIView.inheritedAnimationDuration;
    if (duration <= 0 || duration > 1) duration = 0.20;
    [UIView animateWithDuration:duration
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionCurveEaseInOut |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{ host.alpha = opacity; } completion:nil];
}

static void UpdateButton(UIView *controls) {
    UIView *player = FindPlayer(controls);
    UIView *host = objc_getAssociatedObject(controls, &HostKey);
    BOOL fits = controls.window && player && CGRectGetHeight(controls.bounds) >= 126;
    if (!fits) {
        host.hidden = YES;
        return;
    }

    BOOL visible = ControlsAreVisible(controls);
    CGRect safe = UIEdgeInsetsInsetRect(controls.bounds, controls.safeAreaInsets);
    const CGFloat rowHeight = 40;
    const CGFloat touchSize = 44;
    CGRect slot = CGRectMake(CGRectGetMinX(safe) + 8, CGRectGetMinY(safe) + 50,
                             rowHeight, rowHeight);
    // Match the second row's center while keeping a 44 pt touch target.
    CGFloat expansion = (touchSize - rowHeight) / 2;
    CGRect frame = CGRectInset(slot, -expansion, -expansion);
    UIButton *button = objc_getAssociatedObject(controls, &ButtonKey);
    if (!host) {
        static YTMirrorButtonTarget *target;
        if (!target) target = [YTMirrorButtonTarget new];

        host = [[UIView alloc] initWithFrame:frame];
        host.hidden = YES;
        host.alpha = visible ? 1 : 0;
        host.userInteractionEnabled = visible;
        host.accessibilityElementsHidden = !visible;

        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = host.bounds;
        button.accessibilityIdentifier = @"YTMirror.PlayerButton";
        button.accessibilityLabel = @"左右镜像";
        [button addTarget:target action:@selector(keepControlsVisible:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:target action:@selector(toggleMirror:) forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:button];
        objc_setAssociatedObject(controls, &HostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(controls, &ButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Preserve the last laid-out position while the controls fade out.
    [UIView performWithoutAnimation:^{
        if (visible || host.hidden) {
            if (!CGRectEqualToRect(host.frame, frame)) host.frame = frame;
        }
        if (host.superview != controls) [controls addSubview:host];
        host.hidden = NO;
    }];

    YTMirrorState *state = objc_getAssociatedObject(player, &StateKey);
    SetButtonState(button, state.enabled);
    SetHostVisible(host, visible);
}

static void UpdateControlsVisibility(UIView *view, BOOL visible) {
    if ([view isKindOfClass:ControlsClass]) {
        objc_setAssociatedObject(view, &ControlsVisibleKey, @(visible), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (visible) [view setNeedsLayout];
        SetHostVisible(objc_getAssociatedObject(view, &HostKey), visible);
        return;
    }
    for (UIView *child in view.subviews) UpdateControlsVisibility(child, visible);
}

static void InstallViewCallback(Class cls, SEL selector, void (^callback)(UIView *)) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP original = method_getImplementation(method);
    IMP hook = imp_implementationWithBlock(^(UIView *view) {
        ((void (*)(id, SEL))original)(view, selector);
        callback(view);
    });
    if (!class_addMethod(cls, selector, hook, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, selector, hook, method_getTypeEncoding(method));
    }
}

static void InstallVisibility(Class cls, SEL selector) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 3) return;
    IMP original = method_getImplementation(method);
    IMP hook = imp_implementationWithBlock(^(UIView *view, BOOL visible) {
        ((void (*)(id, SEL, BOOL))original)(view, selector, visible);
        BOOL shown = selector == @selector(setHidden:) ? !view.hidden : visible;
        objc_setAssociatedObject(view, &ControlsVisibleKey, @(shown), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UpdateControlsVisibility(view, shown);
    });
    if (!class_addMethod(cls, selector, hook, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, selector, hook, method_getTypeEncoding(method));
    }
}

__attribute__((constructor))
static void YTMirrorStart(void) {
    if (![NSBundle.mainBundle.executableURL.lastPathComponent isEqualToString:@"YouTube"]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        PlayerClass = NSClassFromString(@"YTPlayerView");
        ControlsClass = NSClassFromString(@"YTMainAppControlsOverlayView");
        if (!PlayerClass || !ControlsClass) return;
        InstallViewCallback(ControlsClass, @selector(layoutSubviews), ^(UIView *controls) { UpdateButton(controls); });
        InstallViewCallback(ControlsClass, @selector(didMoveToWindow), ^(UIView *controls) { UpdateButton(controls); });
        InstallViewCallback(PlayerClass, @selector(layoutSubviews), ^(UIView *player) {
            YTMirrorState *state = objc_getAssociatedObject(player, &StateKey);
            if (state.enabled) UpdateRenderers(state, VideoRenderers(player));
        });
        InstallVisibility(ControlsClass, @selector(setHidden:));
        Class overlay = NSClassFromString(@"YTMainAppVideoPlayerOverlayView");
        for (Class cls in @[ControlsClass, overlay ?: ControlsClass]) {
            InstallVisibility(cls, NSSelectorFromString(@"setOverlayVisible:"));
            InstallVisibility(cls, NSSelectorFromString(@"setControlsOverlayVisible:"));
            if (!overlay) break;
        }
    });
}
