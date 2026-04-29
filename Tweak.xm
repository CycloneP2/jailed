#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

// ============================================
// DATA STRUCTURES
// ============================================
typedef struct { float x, y, z; } Vector3;

// ============================================
// OFFSETS (HASIL DUMP LO)
// ============================================
#define RVA_BATTLE_MANAGER_INST 0xADC8A0   
#define OFF_SHOW_PLAYERS        0x78        
#define OFF_SHOW_MONSTERS       0x80        
#define OFF_LOCAL_PLAYER        0x50        

#define OFF_ENTITY_POS          0x310       
#define OFF_ENTITY_CAMP         0xD8        
#define OFF_ENTITY_HP           0x1AC       
#define OFF_ENTITY_HP_MAX       0x1B0       
#define OFF_ENTITY_SHIELD       0x1B8       
#define OFF_PLAYER_HERO_NAME    0x918       
#define OFF_ENTITY_ID           0x194       

#define RVA_WORLD_TO_SCREEN     0x89FE040   
#define RVA_CAMERA_MAIN         0x89FF130   

// ============================================
// ESP SETTINGS (DEFAULT ON)
// ============================================
static BOOL espEnabled = YES;
static BOOL showEnemyBox = YES;
static BOOL showEnemyHp = YES;
static BOOL showEnemyName = YES;
static BOOL showEnemyLine = YES;
static BOOL showMonsterEsp = YES;
static BOOL showTeamEsp = NO;
static BOOL showDistance = YES;

static float enemyR = 1.0, enemyG = 0.2, enemyB = 0.2;
static float teamR = 0.2, teamG = 0.8, teamB = 0.2;
static float monsterR = 1.0, monsterG = 0.8, monsterB = 0.0;

static uintptr_t g_unityBase = 0;

// ============================================
// UTILITIES
// ============================================

uintptr_t get_base(const char* name) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* img = _dyld_get_image_name(i);
        if (img && strstr(img, name)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

bool is_valid(uintptr_t ptr) {
    return (ptr > 0x100000000 && ptr < 0x2000000000 && (ptr & 0x3) == 0);
}

NSString* readIl2CppString(uintptr_t ptr) {
    if (!is_valid(ptr)) return nil;
    int len = *(int*)(ptr + 0x10);
    if (len <= 0 || len > 64) return nil;
    uintptr_t dataPtr = ptr + 0x14;
    if (!is_valid(dataPtr)) return nil;
    return [NSString stringWithCharacters:(uint16_t*)dataPtr length:len];
}

float distance3D(Vector3 a, Vector3 b) {
    float dx = a.x - b.x;
    float dy = a.y - b.y;
    float dz = a.z - b.z;
    return sqrtf(dx*dx + dy*dy + dz*dz);
}

// ============================================
// ESP OVERLAY VIEW
// ============================================

@interface ESPOverlayView : UIView
@end

@implementation ESPOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
        
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(redrawESP)];
        [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)redrawESP {
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!espEnabled || !g_unityBase) return;
    
    @try {
        uintptr_t bmAddr = *(uintptr_t*)(g_unityBase + RVA_BATTLE_MANAGER_INST);
        if (!is_valid(bmAddr)) return;
        
        uintptr_t bm = *(uintptr_t*)bmAddr;
        if (!is_valid(bm)) {
            bm = bmAddr;
            if (!is_valid(bm)) return;
        }
        
        void* (*get_main)() = (void*(*)())(g_unityBase + RVA_CAMERA_MAIN);
        if (!get_main) return;
        void* cam = get_main();
        if (!cam) return;
        
        Vector3 (*w2s)(void*, Vector3) = (Vector3(*)(void*, Vector3))(g_unityBase + RVA_WORLD_TO_SCREEN);
        if (!w2s) return;
        
        uintptr_t localPlayer = *(uintptr_t*)(bm + OFF_LOCAL_PLAYER);
        int myTeam = 0;
        Vector3 myPos = {0,0,0};
        
        if (is_valid(localPlayer)) {
            myTeam = *(int*)(localPlayer + OFF_ENTITY_CAMP);
            myPos = *(Vector3*)(localPlayer + OFF_ENTITY_POS);
        }
        
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (!ctx) return;
        
        CGContextSaveGState(ctx);
        
        // ========== DRAW PLAYERS ==========
        uintptr_t playerList = *(uintptr_t*)(bm + OFF_SHOW_PLAYERS);
        if (is_valid(playerList)) {
            uintptr_t playerArray = *(uintptr_t*)(playerList + 0x10);
            int playerCount = *(int*)(playerList + 0x18);
            
            if (playerCount > 0 && playerCount <= 60 && is_valid(playerArray)) {
                for (int i = 0; i < playerCount; i++) {
                    uintptr_t entity = *(uintptr_t*)(playerArray + 0x20 + (i * 8));
                    if (!is_valid(entity)) continue;
                    
                    int team = *(int*)(entity + OFF_ENTITY_CAMP);
                    
                    if (team == myTeam && !showTeamEsp) continue;
                    
                    UIColor *color;
                    if (team == myTeam) {
                        color = [UIColor colorWithRed:teamR green:teamG blue:teamB alpha:1.0];
                    } else {
                        color = [UIColor colorWithRed:enemyR green:enemyG blue:enemyB alpha:1.0];
                    }
                    
                    [self drawEntity:entity withCam:cam w2s:w2s ctx:ctx rect:rect 
                                color:color isTeam:(team == myTeam) myPos:myPos];
                }
            }
        }
        
        // ========== DRAW MONSTERS ==========
        if (showMonsterEsp) {
            uintptr_t monsterList = *(uintptr_t*)(bm + OFF_SHOW_MONSTERS);
            if (is_valid(monsterList)) {
                uintptr_t monsterArray = *(uintptr_t*)(monsterList + 0x10);
                int monsterCount = *(int*)(monsterList + 0x18);
                
                if (monsterCount > 0 && monsterCount <= 30 && is_valid(monsterArray)) {
                    for (int i = 0; i < monsterCount; i++) {
                        uintptr_t entity = *(uintptr_t*)(monsterArray + 0x20 + (i * 8));
                        if (!is_valid(entity)) continue;
                        
                        int m_id = *(int*)(entity + OFF_ENTITY_ID);
                        if (m_id == 1001 || m_id == 1002 || m_id == 2001 || m_id == 3001 || m_id == 3002) {
                            [self drawMonster:entity withCam:cam w2s:w2s ctx:ctx rect:rect 
                                         color:[UIColor colorWithRed:monsterR green:monsterG blue:monsterB alpha:1.0]
                                        myPos:myPos];
                        }
                    }
                }
            }
        }
        
        CGContextRestoreGState(ctx);
        
    } @catch (NSException *e) {}
}

- (void)drawEntity:(uintptr_t)entity withCam:(void*)cam w2s:(Vector3(*)(void*, Vector3))w2s 
               ctx:(CGContextRef)ctx rect:(CGRect)rect color:(UIColor*)color 
             isTeam:(BOOL)isTeam myPos:(Vector3)myPos {
    
    Vector3 pos = *(Vector3*)(entity + OFF_ENTITY_POS);
    Vector3 screenPos = w2s(cam, pos);
    
    if (screenPos.z < 0.5f) return;
    
    float x = screenPos.x;
    float y = rect.size.height - screenPos.y;
    
    float boxWidth = 600.0f / screenPos.z;
    float boxHeight = boxWidth * 1.3f;
    
    if (boxWidth > 150) boxWidth = 150;
    if (boxHeight > 195) boxHeight = 195;
    if (boxWidth < 25) boxWidth = 25;
    if (boxHeight < 33) boxHeight = 33;
    
    // 1. ESP BOX
    if (showEnemyBox) {
        CGContextSetStrokeColorWithColor(ctx, color.CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight, boxWidth, boxHeight));
    }
    
    // 2. SNAPLINE
    if (showEnemyLine) {
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.4].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, rect.size.width/2, rect.size.height/2);
        CGContextAddLineToPoint(ctx, x, y);
        CGContextStrokePath(ctx);
    }
    
    // 3. HEALTH BAR
    if (showEnemyHp) {
        int hp = *(int*)(entity + OFF_ENTITY_HP);
        int maxHp = *(int*)(entity + OFF_ENTITY_HP_MAX);
        int shield = *(int*)(entity + OFF_ENTITY_SHIELD);
        
        if (maxHp > 0) {
            float hpPercent = (float)hp / (float)maxHp;
            float shieldPercent = (float)shield / (float)maxHp;
            
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.15 alpha:0.8].CGColor);
            CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 8, boxWidth, 4));
            
            UIColor *hpColor;
            if (hpPercent > 0.6) hpColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1.0];
            else if (hpPercent > 0.3) hpColor = [UIColor yellowColor];
            else hpColor = [UIColor redColor];
            
            CGContextSetFillColorWithColor(ctx, hpColor.CGColor);
            CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 8, boxWidth * hpPercent, 4));
            
            if (shield > 0 && shieldPercent > 0) {
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.85 alpha:0.9].CGColor);
                CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 8, boxWidth * fmin(shieldPercent, 1.0), 4));
            }
            
            NSString *hpText = [NSString stringWithFormat:@"❤️ %d", hp];
            UIFont *hpFont = [UIFont boldSystemFontOfSize:10];
            NSDictionary *hpAttrs = @{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: hpFont};
            [hpText drawAtPoint:CGPointMake(x + boxWidth/2 + 3, y - boxHeight - 6) withAttributes:hpAttrs];
        }
    }
    
    // 4. HERO NAME
    if (showEnemyName && !isTeam) {
        uintptr_t namePtr = *(uintptr_t*)(entity + OFF_PLAYER_HERO_NAME);
        NSString *heroName = readIl2CppString(namePtr);
        if (heroName && heroName.length > 0) {
            UIFont *nameFont = [UIFont boldSystemFontOfSize:10];
            NSDictionary *nameAttrs = @{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: nameFont};
            CGSize nameSize = [heroName sizeWithAttributes:nameAttrs];
            [heroName drawAtPoint:CGPointMake(x - nameSize.width/2, y - boxHeight - 20) withAttributes:nameAttrs];
        }
    }
    
    // 5. DISTANCE
    if (showDistance) {
        float dist = distance3D(myPos, pos);
        if (dist > 0 && dist < 500) {
            NSString *distText = [NSString stringWithFormat:@"%.0fm", dist];
            UIFont *distFont = [UIFont systemFontOfSize:9];
            NSDictionary *distAttrs = @{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0], NSFontAttributeName: distFont};
            [distText drawAtPoint:CGPointMake(x - 15, y + 5) withAttributes:distAttrs];
        }
    }
}

- (void)drawMonster:(uintptr_t)entity withCam:(void*)cam w2s:(Vector3(*)(void*, Vector3))w2s 
                ctx:(CGContextRef)ctx rect:(CGRect)rect color:(UIColor*)color myPos:(Vector3)myPos {
    
    Vector3 pos = *(Vector3*)(entity + OFF_ENTITY_POS);
    Vector3 screenPos = w2s(cam, pos);
    
    if (screenPos.z < 0.5f) return;
    
    float x = screenPos.x;
    float y = rect.size.height - screenPos.y;
    float boxWidth = 500.0f / screenPos.z;
    float boxHeight = boxWidth * 1.2f;
    
    if (boxWidth > 120) boxWidth = 120;
    if (boxHeight > 144) boxHeight = 144;
    if (boxWidth < 20) boxWidth = 20;
    
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight, boxWidth, boxHeight));
    
    int hp = *(int*)(entity + OFF_ENTITY_HP);
    int maxHp = *(int*)(entity + OFF_ENTITY_HP_MAX);
    if (maxHp > 0) {
        float hpPercent = (float)hp / (float)maxHp;
        
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.15 alpha:0.8].CGColor);
        CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 6, boxWidth, 3));
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextFillRect(ctx, CGRectMake(x - boxWidth/2, y - boxHeight - 6, boxWidth * hpPercent, 3));
    }
    
    int m_id = *(int*)(entity + OFF_ENTITY_ID);
    NSString *monsterName = @"🐉 MONSTER";
    if (m_id == 1001 || m_id == 1002) monsterName = @"👑 LORD";
    else if (m_id == 2001) monsterName = @"🐢 TURTLE";
    else if (m_id == 3001 || m_id == 3002) monsterName = @"⚡ BUFF";
    
    UIFont *nameFont = [UIFont boldSystemFontOfSize:9];
    NSDictionary *attrs = @{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: nameFont};
    [monsterName drawAtPoint:CGPointMake(x - 25, y - boxHeight - 15) withAttributes:attrs];
    
    if (showDistance) {
        float dist = distance3D(myPos, pos);
        if (dist > 0 && dist < 500) {
            NSString *distText = [NSString stringWithFormat:@"%.0fm", dist];
            UIFont *distFont = [UIFont systemFontOfSize:9];
            NSDictionary *distAttrs = @{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0], NSFontAttributeName: distFont};
            [distText drawAtPoint:CGPointMake(x - 15, y + 5) withAttributes:distAttrs];
        }
    }
}

@end

// ============================================
// MENU MANAGER
// ============================================

@interface ESPMenuManager : NSObject
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *menuPanel;
+ (instancetype)shared;
- (void)setupWithWindow:(UIWindow *)window;
- (void)toggleMenu;
- (void)handlePan:(UIPanGestureRecognizer *)p;
- (void)createMenu;
- (void)updateSwitch:(UISwitch *)sender;
@end

@implementation ESPMenuManager

+ (instancetype)shared {
    static ESPMenuManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setupWithWindow:(UIWindow *)window {
    self.fab = [UIButton buttonWithType:UIButtonTypeCustom];
    self.fab.frame = CGRectMake(15, 120, 55, 55);
    self.fab.backgroundColor = [UIColor colorWithRed:0.1 green:0.2 blue:0.5 alpha:0.95];
    self.fab.layer.cornerRadius = 27.5;
    self.fab.layer.shadowColor = [UIColor cyanColor].CGColor;
    self.fab.layer.shadowOffset = CGSizeMake(0, 0);
    self.fab.layer.shadowOpacity = 0.6;
    self.fab.layer.shadowRadius = 4;
    [self.fab setTitle:@"ESP" forState:UIControlStateNormal];
    self.fab.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.fab addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.fab addGestureRecognizer:pan];
    [window addSubview:self.fab];
    
    ESPOverlayView *espView = [[ESPOverlayView alloc] initWithFrame:window.bounds];
    espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:espView];
    
    [window bringSubviewToFront:espView];
    [window bringSubviewToFront:self.fab];
}

- (void)handlePan:(UIPanGestureRecognizer *)p {
    CGPoint translation = [p translationInView:self.fab.superview];
    self.fab.center = CGPointMake(self.fab.center.x + translation.x, self.fab.center.y + translation.y);
    [p setTranslation:CGPointZero inView:self.fab.superview];
}

- (void)toggleMenu {
    if (!self.menuPanel) {
        [self createMenu];
    }
    self.menuPanel.hidden = !self.menuPanel.hidden;
}

- (void)createMenu {
    UIWindow *window = self.fab.superview;
    if (!window) return;
    
    self.menuPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 380)];
    self.menuPanel.center = window.center;
    self.menuPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.menuPanel.layer.cornerRadius = 18;
    self.menuPanel.layer.borderWidth = 1.5;
    self.menuPanel.layer.borderColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:1.0].CGColor;
    self.menuPanel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.menuPanel.layer.shadowOffset = CGSizeMake(0, 2);
    self.menuPanel.layer.shadowOpacity = 0.5;
    self.menuPanel.layer.shadowRadius = 8;
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, 260, 28)];
    title.text = @"⚡ EDGY ESP ⚡";
    title.textColor = [UIColor cyanColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.font = [UIFont boldSystemFontOfSize:17];
    [self.menuPanel addSubview:title];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(215, 12, 35, 28);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.menuPanel addSubview:closeBtn];
    
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(15, 48, 230, 0.5)];
    sep.backgroundColor = [UIColor grayColor];
    [self.menuPanel addSubview:sep];
    
    __weak typeof(self) weakSelf = self;
    void (^addToggle)(NSString*, BOOL*, int) = ^(NSString *title, BOOL *value, int yOffset) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, yOffset, 160, 32)];
        lbl.text = title;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont systemFontOfSize:14];
        [weakSelf.menuPanel addSubview:lbl];
        
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(190, yOffset, 50, 32)];
        sw.on = *value;
        sw.onTintColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        objc_setAssociatedObject(sw, "valuePtr", [NSValue valueWithPointer:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sw addTarget:weakSelf action:@selector(updateSwitch:) forControlEvents:UIControlEventValueChanged];
        [weakSelf.menuPanel addSubview:sw];
    };
    
    addToggle(@"🎯 ESP MASTER", &espEnabled, 60);
    addToggle(@"📦 Enemy Box", &showEnemyBox, 100);
    addToggle(@"❤️ Enemy HP", &showEnemyHp, 140);
    addToggle(@"🏷️ Enemy Name", &showEnemyName, 180);
    addToggle(@"📏 Distance", &showDistance, 220);
    addToggle(@"🔗 Snapline", &showEnemyLine, 260);
    addToggle(@"👥 Show Team", &showTeamEsp, 300);
    addToggle(@"🐉 Monster ESP", &showMonsterEsp, 340);
    
    [window addSubview:self.menuPanel];
}

- (void)updateSwitch:(UISwitch *)sender {
    NSValue *val = objc_getAssociatedObject(sender, "valuePtr");
    BOOL *ptr = (BOOL *)[val pointerValue];
    if (ptr) *ptr = sender.on;
}

@end

// ============================================
// LOGOS HOOK - INJECT KE GAME
// ============================================

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL ret = %orig;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        g_unityBase = get_base("UnityFramework");
        
        if (!g_unityBase) {
            g_unityBase = get_base("Unity");
        }
        if (!g_unityBase) {
            g_unityBase = get_base("MobileMLBB");
        }
        
        if (g_unityBase) {
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            if (!keyWindow) {
                keyWindow = [UIApplication sharedApplication].windows.firstObject;
            }
            if (keyWindow) {
                [[ESPMenuManager shared] setupWithWindow:keyWindow];
            }
        }
    });
    
    return ret;
}

%end

%ctor {
    %init;
    NSLog(@"✅ EDGY ESP MLBB LOADED");
}
