# Closed-Lid Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Xcode template into Workdeck — a macOS menu bar app whose first tool, Closed-Lid Mode, keeps the Mac awake with the lid closed via a privileged launchd helper, with battery and thermal safeguards.

**Architecture:** Two targets plus shared code. The SwiftUI menu bar app (`Workdeck`, unsandboxed, `MainActor` default isolation) owns all policy and talks over XPC to `WorkdeckHelper`, a minimal root launchd daemon registered with `SMAppService` that only runs `pmset -a disablesleep 0|1` and restores sleep when its client disconnects or it starts. `Shared/` holds the XPC protocol and constants compiled into both. System services sit behind protocols so `LidSleepController` is unit-tested with fakes.

**Tech Stack:** Swift 6.4 (Swift 6 language mode), SwiftUI `MenuBarExtra`, Observation, ServiceManagement (`SMAppService`), Foundation XPC (`NSXPCConnection`), IOKit power sources, Synchronization (`Mutex`), Swift Testing, Xcode 27 (project objectVersion 90 with file-system-synchronized groups).

**Spec:** `specs/2026-10-05-closed-lid-mode-design.md`

**Prototype note:** Every code block in this plan was compiled and its tests run (45 tests passing, no warnings) in a scratch copy of this repository on Xcode 27 / macOS 27.0.1 before the plan was written. Copy code verbatim; deviations are the main source of Swift 6 isolation errors.

## Global Constraints

- Platform: macOS only, `SDKROOT = macosx`, deployment target macOS 26.0.
- Swift 6 language mode (`SWIFT_VERSION = 6.0`), strict concurrency, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; helper and test targets: default (nonisolated).
- App: App Sandbox off, Hardened Runtime on, `LSUIElement = YES`.
- App bundle ID `com.appcreators.workdeck`; helper bundle ID and Mach service `com.appcreators.workdeck.helper`; tests `com.appcreators.workdeck.tests`.
- Development team `U7HS7ZJUWC`.
- Menu bar icon: `rectangle.stack` idle, `rectangle.stack.fill` when Closed-Lid Mode is active.
- Battery threshold: default 20 %, range 10–50 %, step 5. Thermal cutoff at `.serious` or `.critical`.
- XPC call timeout: 5 seconds.
- English only for UI strings, code comments, docs, and commit messages.
- Commit messages: plain imperative sentences. **No `Co-Authored-By` trailers and no mention of Claude/AI tools.**
- No third-party dependencies.
- Docs layout: specs in `specs/`, plans in `plans/`, other documentation in `docs/`, `README.md` and `CLAUDE.md` in the root.

**Test command** (used throughout; `-quiet` hides Swift Testing output, so filter instead):

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"
```

Run a single suite by appending `-only-testing:WorkdeckTests/<SuiteName>` after `test`.

## Review Focus

1. User approves the helper in System Settings, then reopens the popover → the toggle becomes usable without relaunching (Task 9: `refreshPicksUpApprovalGrantedInSystemSettings`; Task 11 wires `refresh()` to popover `.task`).
2. User raises the battery threshold above the current charge while the mode is on, on battery → the mode turns off immediately (Task 9: `raisingThresholdAboveChargeTurnsModeOff`; Task 11 wires `SettingsView.onChange`).
3. Battery exactly at the threshold → the mode stays on; only strictly below cuts off (Task 5: `batteryPercent: 20, threshold: 20 → .allow`).
4. Helper replies after the 5 s timeout already fired → the late reply is ignored without a double-resume crash, and the next call on the same connection works (Task 7: `lateReplyAfterTimeoutIsIgnored`).
5. A helper call fails → the controller does not stay "busy"; the error is shown and the toggle stays usable (Task 9: `helperErrorIsSurfacedAndControllerStaysUsable`).

---

## File Structure

```
.gitignore                                   ignore xcuserdata, DerivedData, .DS_Store
README.md                                    user-facing documentation
CLAUDE.md                                    guidance for AI coding agents
docs/testing.md                              manual verification checklist
LaunchDaemons/
  com.appcreators.workdeck.helper.plist      launchd job, copied into the app bundle (not compiled)
Shared/                                      compiled into app and helper
  HelperConstants.swift                      identifiers, code-signing requirements, version(of:)
  HelperProtocol.swift                       @objc XPC protocol
Workdeck/                                    app target (MainActor default isolation)
  App/
    WorkdeckApp.swift                        MenuBarExtra + Settings scenes
    AppDelegate.swift                        owns AppSettings + LidSleepController, launch/terminate hooks
    PopoverView.swift                        popover layout: header, tool rows, Quit
    SettingsView.swift                       Settings window form
  Core/
    AppSettings.swift                        battery threshold (UserDefaults) + launch at login
    HelperClient.swift                       async NSXPCConnection wrapper with timeout
    HelperInstaller.swift                    SMAppService.daemon registration/status
  Features/ClosedLidMode/
    SafeguardPolicy.swift                    PowerSnapshot, CutoffReason, pure policy
    PowerSourceMonitor.swift                 IOKit battery/power-source monitor
    ThermalMonitor.swift                     ProcessInfo thermal-state monitor
    LidSleepController.swift                 @Observable feature state machine
    ClosedLidModeSubtitle.swift              pure mapping state → subtitle text
    ClosedLidModeRow.swift                   popover row view
WorkdeckHelper/                              helper target (root launchd daemon)
  main.swift                                 startup reset + XPC listener
  HelperListenerDelegate.swift               accepts connections, restores sleep on disconnect
  HelperService.swift                        exported XPC object
  CommandRunner.swift                        Process wrapper behind a protocol
  PowerSettings.swift                        pmset read/write + parsing
  SleepSessionTracker.swift                  which connections hold sleep disabled
WorkdeckTests/                               Swift Testing, hosted in Workdeck.app
  Fakes/Fakes.swift                          fakes for controller tests
  *Tests.swift
```

`WorkdeckTests` also compiles `WorkdeckHelper/` sources **except** `main.swift`, `HelperService.swift`, and `HelperListenerDelegate.swift` (they depend on `Shared/`, which the test target does not compile; it gets `Shared/` types via `@testable import Workdeck`). This is configured by the exception set in `project.pbxproj`.

All source folders are Xcode file-system-synchronized groups: creating a file inside them adds it to the right targets automatically. Never edit `project.pbxproj` for new source files.

---

### Task 1: Restructure the Xcode project into app, helper, and test targets

**Files:**
- Delete: `Workdeck/MyApp.swift`, `Workdeck/ContentView.swift`
- Replace: `Workdeck.xcodeproj/project.pbxproj`
- Create: `Workdeck.xcodeproj/xcshareddata/xcschemes/Workdeck.xcscheme`
- Create: `.gitignore`
- Create: `Workdeck/App/WorkdeckApp.swift` (temporary placeholder UI, replaced in Task 11)
- Create: `WorkdeckHelper/main.swift` (temporary stub, replaced in Task 4)
- Create: `Shared/HelperConstants.swift`, `Shared/HelperProtocol.swift`
- Create: `LaunchDaemons/com.appcreators.workdeck.helper.plist`
- Test: `WorkdeckTests/HelperConstantsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `nonisolated enum HelperConstants` with `static let appIdentifier: String`, `machServiceName: String`, `launchDaemonPlistName: String`, `teamIdentifier: String`, `errorDomain: String`, `clientRequirement: String`, `helperRequirement: String`, `static func version(of bundle: Bundle) -> String` (format `"<CFBundleShortVersionString> (<CFBundleVersion>)"`, e.g. `"1.0 (1)"`).
  - `@objc nonisolated protocol HelperProtocol` with `setSleepDisabled(_:reply: @Sendable (NSError?) -> Void)`, `isSleepDisabled(reply: @Sendable (Bool, NSError?) -> Void)`, `version(reply: @Sendable (String) -> Void)`.
  - Scheme `Workdeck` with test action running `WorkdeckTests`.

- [ ] **Step 1: Remove template sources and untrack per-user Xcode data**

```bash
git rm Workdeck/MyApp.swift Workdeck/ContentView.swift
git rm -r --cached Workdeck.xcodeproj/xcuserdata
mkdir -p Workdeck/App Workdeck/Core Workdeck/Features/ClosedLidMode WorkdeckHelper Shared LaunchDaemons WorkdeckTests/Fakes Workdeck.xcodeproj/xcshareddata/xcschemes
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
.DS_Store
xcuserdata/
DerivedData/
build/
*.xcuserstate
```

- [ ] **Step 3: Replace `Workdeck.xcodeproj/project.pbxproj` with exactly this content**

The IDs follow a readable pattern: `…01xx…` app, `…02xx…` helper, `…03xx…` tests. The app target embeds the helper binary into `Contents/MacOS` (`dstSubfolderSpec = 6`) and the launchd plist into `Contents/Library/LaunchDaemons` (`dstSubfolderSpec = 1`), and depends on the helper target.

```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 90;
	objects = {

/* Begin PBXBuildFile section */
		000000000000000150000001 /* WorkdeckHelper in Embed Helper */ = {isa = PBXBuildFile; fileRef = 000000000000000000000121 /* WorkdeckHelper */; };
		000000000000000160000001 /* com.appcreators.workdeck.helper.plist in Embed Launch Daemon */ = {isa = PBXBuildFile; fileRef = 000000000000000000000130 /* com.appcreators.workdeck.helper.plist */; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		000000000000000170000001 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 000000000000000000000000 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = 000000000000000200000000;
			remoteInfo = WorkdeckHelper;
		};
		000000000000000370000001 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 000000000000000000000000 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = 000000000000000100000000;
			remoteInfo = Workdeck;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		000000000000000150000000 /* Embed Helper */ = {
			isa = PBXCopyFilesBuildPhase;
			dstPath = "";
			dstSubfolderSpec = 6;
			files = (
				000000000000000150000001 /* WorkdeckHelper in Embed Helper */,
			);
			name = "Embed Helper";
		};
		000000000000000160000000 /* Embed Launch Daemon */ = {
			isa = PBXCopyFilesBuildPhase;
			dstPath = Contents/Library/LaunchDaemons;
			dstSubfolderSpec = 1;
			files = (
				000000000000000160000001 /* com.appcreators.workdeck.helper.plist in Embed Launch Daemon */,
			);
			name = "Embed Launch Daemon";
		};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
		000000000000000000000120 /* Workdeck.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Workdeck.app; sourceTree = BUILT_PRODUCTS_DIR; };
		000000000000000000000121 /* WorkdeckHelper */ = {isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; includeInIndex = 0; path = WorkdeckHelper; sourceTree = BUILT_PRODUCTS_DIR; };
		000000000000000000000122 /* WorkdeckTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = WorkdeckTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		000000000000000000000130 /* com.appcreators.workdeck.helper.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = com.appcreators.workdeck.helper.plist; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		000000000000000400000000 /* Exceptions for "WorkdeckHelper" folder in "WorkdeckTests" target */ = {
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				HelperListenerDelegate.swift,
				HelperService.swift,
				main.swift,
			);
			target = 000000000000000300000000 /* WorkdeckTests */;
		};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		000000000000000000000010 /* Workdeck */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Workdeck;
			sourceTree = "<group>";
		};
		000000000000000000000011 /* WorkdeckHelper */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				000000000000000400000000 /* Exceptions for "WorkdeckHelper" folder in "WorkdeckTests" target */,
			);
			path = WorkdeckHelper;
			sourceTree = "<group>";
		};
		000000000000000000000012 /* Shared */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = Shared;
			sourceTree = "<group>";
		};
		000000000000000000000013 /* WorkdeckTests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WorkdeckTests;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		000000000000000130000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
			);
		};
		000000000000000230000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
			);
		};
		000000000000000330000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
			);
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		000000000000000000000001 = {
			isa = PBXGroup;
			children = (
				000000000000000000000010 /* Workdeck */,
				000000000000000000000011 /* WorkdeckHelper */,
				000000000000000000000012 /* Shared */,
				000000000000000000000013 /* WorkdeckTests */,
				000000000000000000000014 /* LaunchDaemons */,
				000000000000000000000020 /* Products */,
			);
			sourceTree = "<group>";
		};
		000000000000000000000014 /* LaunchDaemons */ = {
			isa = PBXGroup;
			children = (
				000000000000000000000130 /* com.appcreators.workdeck.helper.plist */,
			);
			path = LaunchDaemons;
			sourceTree = "<group>";
		};
		000000000000000000000020 /* Products */ = {
			isa = PBXGroup;
			children = (
				000000000000000000000120 /* Workdeck.app */,
				000000000000000000000121 /* WorkdeckHelper */,
				000000000000000000000122 /* WorkdeckTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		000000000000000100000000 /* Workdeck */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000110000000 /* Build configuration list for PBXNativeTarget "Workdeck" */;
			buildPhases = (
				000000000000000120000000 /* Sources */,
				000000000000000130000000 /* Frameworks */,
				000000000000000140000000 /* Resources */,
				000000000000000150000000 /* Embed Helper */,
				000000000000000160000000 /* Embed Launch Daemon */,
			);
			buildRules = (
			);
			dependencies = (
				000000000000000170000000 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000010 /* Workdeck */,
				000000000000000000000012 /* Shared */,
			);
			name = Workdeck;
			productName = Workdeck;
			productReference = 000000000000000000000120 /* Workdeck.app */;
			productType = "com.apple.product-type.application";
		};
		000000000000000200000000 /* WorkdeckHelper */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000210000000 /* Build configuration list for PBXNativeTarget "WorkdeckHelper" */;
			buildPhases = (
				000000000000000220000000 /* Sources */,
				000000000000000230000000 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000011 /* WorkdeckHelper */,
				000000000000000000000012 /* Shared */,
			);
			name = WorkdeckHelper;
			productName = WorkdeckHelper;
			productReference = 000000000000000000000121 /* WorkdeckHelper */;
			productType = "com.apple.product-type.tool";
		};
		000000000000000300000000 /* WorkdeckTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000310000000 /* Build configuration list for PBXNativeTarget "WorkdeckTests" */;
			buildPhases = (
				000000000000000320000000 /* Sources */,
				000000000000000330000000 /* Frameworks */,
				000000000000000340000000 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				000000000000000370000000 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000013 /* WorkdeckTests */,
				000000000000000000000011 /* WorkdeckHelper */,
			);
			name = WorkdeckTests;
			productName = WorkdeckTests;
			productReference = 000000000000000000000122 /* WorkdeckTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		000000000000000000000000 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2630;
				LastUpgradeCheck = 2700;
				TargetAttributes = {
					000000000000000100000000 = {
						CreatedOnToolsVersion = 26.3;
					};
					000000000000000200000000 = {
						CreatedOnToolsVersion = 27.0;
					};
					000000000000000300000000 = {
						CreatedOnToolsVersion = 27.0;
						TestTargetID = 000000000000000100000000;
					};
				};
			};
			buildConfigurationList = 000000000000000010000000 /* Build configuration list for PBXProject "Workdeck" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = 000000000000000000000001;
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 90;
			productRefGroup = 000000000000000000000020 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				000000000000000100000000 /* Workdeck */,
				000000000000000200000000 /* WorkdeckHelper */,
				000000000000000300000000 /* WorkdeckTests */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		000000000000000140000000 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
			);
		};
		000000000000000340000000 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
			);
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		000000000000000120000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
		000000000000000220000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
		000000000000000320000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		000000000000000170000000 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = 000000000000000200000000 /* WorkdeckHelper */;
			targetProxy = 000000000000000170000001 /* PBXContainerItemProxy */;
		};
		000000000000000370000000 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = 000000000000000100000000 /* Workdeck */;
			targetProxy = 000000000000000370000001 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		000000000000000011000000 /* Debug configuration for PBXProject "Workdeck" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				CODE_SIGN_STYLE = Automatic;
				COPY_PHASE_STRIP = NO;
				CURRENT_PROJECT_VERSION = 1;
				DEAD_CODE_STRIPPING = YES;
				DEBUG_INFORMATION_FORMAT = dwarf;
				DEVELOPMENT_TEAM = U7HS7ZJUWC;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MARKETING_VERSION = 1.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_VERSION = 6.0;
			};
			name = Debug;
		};
		000000000000000012000000 /* Release configuration for PBXProject "Workdeck" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				CLANG_ENABLE_OBJC_WEAK = YES;
				CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES;
				CLANG_WARN_BOOL_CONVERSION = YES;
				CLANG_WARN_COMMA = YES;
				CLANG_WARN_CONSTANT_CONVERSION = YES;
				CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES;
				CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
				CLANG_WARN_DOCUMENTATION_COMMENTS = YES;
				CLANG_WARN_EMPTY_BODY = YES;
				CLANG_WARN_ENUM_CONVERSION = YES;
				CLANG_WARN_INFINITE_RECURSION = YES;
				CLANG_WARN_INT_CONVERSION = YES;
				CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES;
				CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES;
				CLANG_WARN_OBJC_LITERAL_CONVERSION = YES;
				CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
				CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES;
				CLANG_WARN_RANGE_LOOP_ANALYSIS = YES;
				CLANG_WARN_STRICT_PROTOTYPES = YES;
				CLANG_WARN_SUSPICIOUS_MOVE = YES;
				CLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;
				CLANG_WARN_UNREACHABLE_CODE = YES;
				CLANG_WARN__DUPLICATE_METHOD_MATCH = YES;
				CODE_SIGN_STYLE = Automatic;
				COPY_PHASE_STRIP = NO;
				CURRENT_PROJECT_VERSION = 1;
				DEAD_CODE_STRIPPING = YES;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				DEVELOPMENT_TEAM = U7HS7ZJUWC;
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_WARN_64_TO_32_BIT_CONVERSION = YES;
				GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
				GCC_WARN_UNDECLARED_SELECTOR = YES;
				GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
				GCC_WARN_UNUSED_FUNCTION = YES;
				GCC_WARN_UNUSED_VARIABLE = YES;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MARKETING_VERSION = 1.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SDKROOT = macosx;
				STRING_CATALOG_GENERATE_SYMBOLS = YES;
				SWIFT_APPROACHABLE_CONCURRENCY = YES;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;
				SWIFT_VERSION = 6.0;
			};
			name = Release;
		};
		000000000000000111000000 /* Debug configuration for PBXNativeTarget "Workdeck" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ENABLE_APP_SANDBOX = NO;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = Workdeck;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_LSUIElement = YES;
				LD_RUNPATH_SEARCH_PATHS = "@executable_path/../Frameworks";
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
			};
			name = Debug;
		};
		000000000000000112000000 /* Release configuration for PBXNativeTarget "Workdeck" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ENABLE_APP_SANDBOX = NO;
				ENABLE_HARDENED_RUNTIME = YES;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = Workdeck;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools";
				INFOPLIST_KEY_LSUIElement = YES;
				LD_RUNPATH_SEARCH_PATHS = "@executable_path/../Frameworks";
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
			};
			name = Release;
		};
		000000000000000211000000 /* Debug configuration for PBXNativeTarget "WorkdeckHelper" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CREATE_INFOPLIST_SECTION_IN_BINARY = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck.helper;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
			};
			name = Debug;
		};
		000000000000000212000000 /* Release configuration for PBXNativeTarget "WorkdeckHelper" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CREATE_INFOPLIST_SECTION_IN_BINARY = YES;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck.helper;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
			};
			name = Release;
		};
		000000000000000311000000 /* Debug configuration for PBXNativeTarget "WorkdeckTests" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Workdeck.app/Contents/MacOS/Workdeck";
			};
			name = Debug;
		};
		000000000000000312000000 /* Release configuration for PBXNativeTarget "WorkdeckTests" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				BUNDLE_LOADER = "$(TEST_HOST)";
				GENERATE_INFOPLIST_FILE = YES;
				PRODUCT_BUNDLE_IDENTIFIER = com.appcreators.workdeck.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Workdeck.app/Contents/MacOS/Workdeck";
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		000000000000000010000000 /* Build configuration list for PBXProject "Workdeck" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000011000000 /* Debug configuration for PBXProject "Workdeck" */,
				000000000000000012000000 /* Release configuration for PBXProject "Workdeck" */,
			);
			defaultConfigurationName = Release;
		};
		000000000000000110000000 /* Build configuration list for PBXNativeTarget "Workdeck" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000111000000 /* Debug configuration for PBXNativeTarget "Workdeck" */,
				000000000000000112000000 /* Release configuration for PBXNativeTarget "Workdeck" */,
			);
			defaultConfigurationName = Release;
		};
		000000000000000210000000 /* Build configuration list for PBXNativeTarget "WorkdeckHelper" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000211000000 /* Debug configuration for PBXNativeTarget "WorkdeckHelper" */,
				000000000000000212000000 /* Release configuration for PBXNativeTarget "WorkdeckHelper" */,
			);
			defaultConfigurationName = Release;
		};
		000000000000000310000000 /* Build configuration list for PBXNativeTarget "WorkdeckTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000311000000 /* Debug configuration for PBXNativeTarget "WorkdeckTests" */,
				000000000000000312000000 /* Release configuration for PBXNativeTarget "WorkdeckTests" */,
			);
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = 000000000000000000000000 /* Project object */;
}
```

- [ ] **Step 4: Create the shared scheme `Workdeck.xcodeproj/xcshareddata/xcschemes/Workdeck.xcscheme`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "000000000000000100000000"
               BuildableName = "Workdeck.app"
               BlueprintName = "Workdeck"
               ReferencedContainer = "container:Workdeck.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "000000000000000300000000"
               BuildableName = "WorkdeckTests.xctest"
               BlueprintName = "WorkdeckTests"
               ReferencedContainer = "container:Workdeck.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "000000000000000100000000"
            BuildableName = "Workdeck.app"
            BlueprintName = "Workdeck"
            ReferencedContainer = "container:Workdeck.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "000000000000000100000000"
            BuildableName = "Workdeck.app"
            BlueprintName = "Workdeck"
            ReferencedContainer = "container:Workdeck.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

- [ ] **Step 5: Create the placeholder app `Workdeck/App/WorkdeckApp.swift`**

```swift
import SwiftUI

@main
struct WorkdeckApp: App {
    var body: some Scene {
        MenuBarExtra("Workdeck", systemImage: "rectangle.stack") {
            Text("Workdeck")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 6: Create the helper stub `WorkdeckHelper/main.swift`**

```swift
import Foundation

dispatchMain()
```

- [ ] **Step 7: Create the launchd job `LaunchDaemons/com.appcreators.workdeck.helper.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.appcreators.workdeck.helper</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/WorkdeckHelper</string>
	<key>MachServices</key>
	<dict>
		<key>com.appcreators.workdeck.helper</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>com.appcreators.workdeck</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 8: Write the failing test `WorkdeckTests/HelperConstantsTests.swift`**

```swift
import Foundation
import Security
import Testing
@testable import Workdeck

struct HelperConstantsTests {
    @Test func requirementsPinIdentifierAndTeam() {
        #expect(HelperConstants.clientRequirement
            == #"anchor apple generic and identifier "com.appcreators.workdeck" and certificate leaf[subject.OU] = "U7HS7ZJUWC""#)
        #expect(HelperConstants.helperRequirement
            == #"anchor apple generic and identifier "com.appcreators.workdeck.helper" and certificate leaf[subject.OU] = "U7HS7ZJUWC""#)
    }

    @Test(arguments: [HelperConstants.clientRequirement, HelperConstants.helperRequirement])
    func requirementCompiles(_ requirement: String) {
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
    }

    @Test func versionCombinesShortVersionAndBuild() {
        #expect(HelperConstants.version(of: .main) == "1.0 (1)")
    }

    @Test func appBundleEmbedsHelperAndLaunchDaemon() throws {
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let helper = contents.appending(path: "MacOS/WorkdeckHelper")
        let plistURL = contents.appending(path: "Library/LaunchDaemons/\(HelperConstants.launchDaemonPlistName)")
        #expect(FileManager.default.isExecutableFile(atPath: helper.path))

        let plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        #expect(plist["Label"] as? String == HelperConstants.machServiceName)
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/WorkdeckHelper")
        #expect((plist["MachServices"] as? [String: Bool])?[HelperConstants.machServiceName] == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == [HelperConstants.appIdentifier])
    }
}
```

- [ ] **Step 9: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/HelperConstantsTests`
Expected: build fails with `error: cannot find 'HelperConstants' in scope`.

- [ ] **Step 10: Create `Shared/HelperConstants.swift`**

```swift
import Foundation

/// Identifiers and code-signing requirements shared by the app and the privileged helper.
nonisolated enum HelperConstants {
    static let appIdentifier = "com.appcreators.workdeck"
    static let machServiceName = "com.appcreators.workdeck.helper"
    static let launchDaemonPlistName = "com.appcreators.workdeck.helper.plist"
    static let teamIdentifier = "U7HS7ZJUWC"
    static let errorDomain = "com.appcreators.workdeck.helper"

    /// Requirement the helper enforces on every connecting client.
    static let clientRequirement =
        "anchor apple generic and identifier \"\(appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Requirement the app enforces on the helper it connects to.
    static let helperRequirement =
        "anchor apple generic and identifier \"\(machServiceName)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Version string compared between app and helper to detect a stale helper after an update.
    static func version(of bundle: Bundle) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}
```

- [ ] **Step 11: Create `Shared/HelperProtocol.swift`**

```swift
import Foundation

/// XPC interface exported by the privileged helper. Keep it minimal: every method runs as root.
@objc nonisolated protocol HelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void)
    func isSleepDisabled(reply: @escaping @Sendable (Bool, NSError?) -> Void)
    func version(reply: @escaping @Sendable (String) -> Void)
}
```

- [ ] **Step 12: Run the tests to verify they pass**

Run: the test command with `-only-testing:WorkdeckTests/HelperConstantsTests`
Expected: `Test run with 4 tests in 1 suite passed` and `** TEST SUCCEEDED **`.

- [ ] **Step 13: Verify targets and signing**

```bash
xcodebuild -list
xcodebuild -scheme Workdeck -destination 'platform=macOS' -derivedDataPath build/dd build 2>&1 | grep -E "error:|\*\* BUILD"
codesign -dv build/dd/Build/Products/Debug/Workdeck.app/Contents/MacOS/WorkdeckHelper 2>&1 | grep -E "^Identifier|TeamIdentifier|flags"
rm -rf build
```

Expected: targets `Workdeck`, `WorkdeckHelper`, `WorkdeckTests`; `** BUILD SUCCEEDED **`; `Identifier=com.appcreators.workdeck.helper`, `TeamIdentifier=U7HS7ZJUWC`, `flags=0x10000(runtime)`.

- [ ] **Step 14: Commit**

```bash
git add .gitignore Workdeck.xcodeproj Workdeck WorkdeckHelper Shared LaunchDaemons WorkdeckTests
git commit -m "Restructure project into menu bar app, privileged helper, and test targets"
```

---

### Task 2: Initial README.md and CLAUDE.md

**Files:**
- Create: `README.md`
- Create: `CLAUDE.md`

**Interfaces:**
- Consumes: project layout from Task 1.
- Produces: root docs; Task 12 replaces `README.md` with the final version and appends a Verification section to `CLAUDE.md`.

- [ ] **Step 1: Create `README.md`**

````markdown
# Workdeck

A minimal macOS menu bar toolbox for developers.

> Work in progress. The first tool, **Closed-Lid Mode**, keeps your Mac awake while the lid is closed.

## Requirements

- macOS 26 or later
- Xcode 27 to build

## Building

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' build
xcodebuild -scheme Workdeck -destination 'platform=macOS' test
```

Or open `Workdeck.xcodeproj` and run the `Workdeck` scheme. Both the `Workdeck` and `WorkdeckHelper` targets are signed with team `U7HS7ZJUWC`; if you build with a different team, also update `HelperConstants.teamIdentifier`.

## Project Structure

```
Workdeck/          Menu bar app (SwiftUI)
  App/             Scenes and top-level views
  Core/            Helper client and installer, settings
  Features/        One folder per tool
WorkdeckHelper/    Privileged launchd helper
Shared/            Code compiled into both the app and the helper
LaunchDaemons/     launchd job definition embedded in the app bundle
WorkdeckTests/     Unit tests (Swift Testing)
specs/             Design specs
plans/             Implementation plans
```
````

- [ ] **Step 2: Create `CLAUDE.md`**

````markdown
# CLAUDE.md

Guidance for AI coding agents working in this repository.

## Project

Workdeck is a macOS menu bar toolbox for developers. Each tool is one row in the popover and lives in its own folder under `Workdeck/Features/`. The first tool is Closed-Lid Mode, which keeps the Mac awake while the lid is closed.

## Build and Test

- Build: `xcodebuild -scheme Workdeck -destination 'platform=macOS' build`
- Test: `xcodebuild -scheme Workdeck -destination 'platform=macOS' test 2>&1 | grep -E "error:|recorded an issue|Test run with|\*\* TEST"` (`-quiet` hides Swift Testing output)
- Single suite: add `-only-testing:WorkdeckTests/<SuiteName>` after `test`.
- Tests use Swift Testing and are hosted in `Workdeck.app`.

## Architecture

- `Workdeck/` — the menu bar app: SwiftUI, unsandboxed, `MainActor` default actor isolation.
  - `App/` scenes and top-level views; `Core/` helper client, helper installer, settings; `Features/<Tool>/` per-tool logic and views.
- `WorkdeckHelper/` — privileged launchd daemon running as root (no default actor isolation). Registered with `SMAppService.daemon`, reached over XPC.
- `Shared/` — compiled into both targets: the XPC protocol and constants. Types here must be explicitly `nonisolated`.
- `LaunchDaemons/` — launchd job copied into `Workdeck.app/Contents/Library/LaunchDaemons`.
- `WorkdeckTests/` — also compiles `WorkdeckHelper/` sources except `main.swift`, `HelperService.swift`, and `HelperListenerDelegate.swift` (exception set in `project.pbxproj`). Fakes live in `WorkdeckTests/Fakes/`.
- Source folders are Xcode file-system-synchronized groups: new files are picked up automatically. Do not edit `project.pbxproj` to add source files.

## Conventions

- Swift 6 language mode with strict concurrency. Pure value types, and anything called from XPC, IOKit, or other background callbacks, must be explicitly `nonisolated` or `@Sendable`.
- SwiftUI with native controls, system fonts, colors, and SF Symbols; follow the Apple Human Interface Guidelines; keep the UI minimal.
- English only: UI strings, code comments, documentation, commit messages.
- No third-party dependencies without discussing it first.
- Wrap system services (IOKit, `SMAppService`, XPC) behind protocols so controllers can be tested with fakes.

## Helper Rules

- Keep the helper minimal. Do not add XPC methods without an explicit security review.
- Never execute arbitrary commands or accept paths or arguments from the client.
- Every code path that disables sleep must have a matching restore path: normal quit, client crash or disconnect, helper restart, and reboot.
- The code-signing requirements and team ID live in `Shared/HelperConstants.swift`.

## Documentation Layout

- `specs/` design specs, `plans/` implementation plans, `docs/` other documentation, `README.md` and `CLAUDE.md` in the root.

## Git

- No `Co-Authored-By` trailers and no mention of Claude or AI tools in commit messages or PR descriptions.
````

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "Add initial README and CLAUDE.md"
```

---

### Task 3: Helper power settings core

**Files:**
- Create: `WorkdeckHelper/CommandRunner.swift`
- Create: `WorkdeckHelper/PowerSettings.swift`
- Create: `WorkdeckHelper/SleepSessionTracker.swift`
- Test: `WorkdeckTests/PowerSettingsTests.swift`, `WorkdeckTests/SleepSessionTrackerTests.swift`

**Interfaces:**
- Consumes: nothing (these files are compiled into both the helper and the test target).
- Produces:
  - `struct CommandResult: Equatable, Sendable { exitCode: Int32; output: String; errorOutput: String }`
  - `protocol CommandRunner: Sendable { func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult }`
  - `struct ProcessCommandRunner: CommandRunner`
  - `enum PowerSettingsError: LocalizedError, Equatable { case commandFailed(exitCode: Int32, message: String) }`
  - `struct PowerSettings: Sendable { static let pmsetPath; let runner: any CommandRunner; func setSleepDisabled(_:) throws; func isSleepDisabled() throws -> Bool; static func parseSleepDisabled(_:) -> Bool }`
  - `final class SleepSessionTracker: Sendable { func clientDidSet(_ client: ObjectIdentifier, sleepDisabled: Bool); func clientDidDisconnect(_ client: ObjectIdentifier) -> Bool }`

Background: `pmset -g` prints a `SleepDisabled 1` line only while sleep is disabled; when it is 0 the line is usually absent. Test files here do **not** `@testable import Workdeck` — the helper sources are compiled directly into the test bundle.

- [ ] **Step 1: Write the failing test `WorkdeckTests/PowerSettingsTests.swift`**

```swift
import Foundation
import Synchronization
import Testing

final class FakeCommandRunner: CommandRunner {
    private let state: Mutex<(calls: [[String]], result: CommandResult)>

    init(result: CommandResult = CommandResult(exitCode: 0, output: "", errorOutput: "")) {
        state = Mutex((calls: [], result: result))
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
        state.withLock { state in
            state.calls.append([executablePath] + arguments)
            return state.result
        }
    }
}

struct PowerSettingsTests {
    @Test func disablingSleepRunsPmset() throws {
        let runner = FakeCommandRunner()
        try PowerSettings(runner: runner).setSleepDisabled(true)
        #expect(runner.calls == [["/usr/bin/pmset", "-a", "disablesleep", "1"]])
    }

    @Test func enablingSleepRunsPmset() throws {
        let runner = FakeCommandRunner()
        try PowerSettings(runner: runner).setSleepDisabled(false)
        #expect(runner.calls == [["/usr/bin/pmset", "-a", "disablesleep", "0"]])
    }

    @Test func nonZeroExitThrowsWithStderr() {
        let runner = FakeCommandRunner(result: CommandResult(exitCode: 1, output: "", errorOutput: "must be root\n"))
        #expect(throws: PowerSettingsError.commandFailed(exitCode: 1, message: "must be root")) {
            try PowerSettings(runner: runner).setSleepDisabled(true)
        }
    }

    @Test func readsSleepDisabledFromPmsetOutput() throws {
        let output = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep                1\n"
        let runner = FakeCommandRunner(result: CommandResult(exitCode: 0, output: output, errorOutput: ""))
        #expect(try PowerSettings(runner: runner).isSleepDisabled())
        #expect(runner.calls == [["/usr/bin/pmset", "-g"]])
    }

    @Test(arguments: [
        ("System-wide power settings:\nCurrently in use:\n sleep                1 (sleep prevented by powerd)\n", false),
        (" SleepDisabled\t\t0\n", false),
        (" SleepDisabled\t\t1\n", true),
        ("", false),
    ])
    func parsesSleepDisabled(output: String, expected: Bool) {
        #expect(PowerSettings.parseSleepDisabled(output) == expected)
    }
}
```

- [ ] **Step 2: Write the failing test `WorkdeckTests/SleepSessionTrackerTests.swift`**

```swift
import Foundation
import Testing

struct SleepSessionTrackerTests {
    // Keep the objects alive: identifiers of deallocated objects can be reused.
    private let firstClient = NSObject()
    private let secondClient = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(firstClient) }
    private var second: ObjectIdentifier { ObjectIdentifier(secondClient) }

    @Test func lastHolderDisconnectRestoresSleep() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        #expect(tracker.clientDidDisconnect(first))
    }

    @Test func clientThatNeverDisabledSleepDoesNotRestore() {
        let tracker = SleepSessionTracker()
        #expect(!tracker.clientDidDisconnect(first))
    }

    @Test func remainingHolderKeepsSleepDisabled() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.clientDidSet(second, sleepDisabled: true)
        #expect(!tracker.clientDidDisconnect(first))
        #expect(tracker.clientDidDisconnect(second))
    }

    @Test func reEnablingSleepReleasesAllHolders() {
        let tracker = SleepSessionTracker()
        tracker.clientDidSet(first, sleepDisabled: true)
        tracker.clientDidSet(second, sleepDisabled: false)
        #expect(!tracker.clientDidDisconnect(first))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: the test command with `-only-testing:WorkdeckTests/PowerSettingsTests -only-testing:WorkdeckTests/SleepSessionTrackerTests`
Expected: build fails with `cannot find type 'CommandRunner' in scope`.

- [ ] **Step 4: Create `WorkdeckHelper/CommandRunner.swift`**

```swift
import Foundation

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
    let errorOutput: String
}

protocol CommandRunner: Sendable {
    func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunner {
    func run(_ executablePath: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            exitCode: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self),
            errorOutput: String(decoding: errorOutput, as: UTF8.self)
        )
    }
}
```

- [ ] **Step 5: Create `WorkdeckHelper/PowerSettings.swift`**

```swift
import Foundation

enum PowerSettingsError: LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            "pmset failed with exit code \(exitCode): \(message)"
        }
    }
}

/// Reads and writes the system-wide `SleepDisabled` power setting via `pmset`.
struct PowerSettings: Sendable {
    static let pmsetPath = "/usr/bin/pmset"

    let runner: any CommandRunner

    func setSleepDisabled(_ disabled: Bool) throws {
        let result = try runner.run(Self.pmsetPath, ["-a", "disablesleep", disabled ? "1" : "0"])
        try Self.check(result)
    }

    func isSleepDisabled() throws -> Bool {
        let result = try runner.run(Self.pmsetPath, ["-g"])
        try Self.check(result)
        return Self.parseSleepDisabled(result.output)
    }

    /// `pmset -g` prints a `SleepDisabled 1` line only while sleep is disabled.
    static func parseSleepDisabled(_ output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false
    }

    private static func check(_ result: CommandResult) throws {
        guard result.exitCode == 0 else {
            let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PowerSettingsError.commandFailed(exitCode: result.exitCode, message: message)
        }
    }
}
```

- [ ] **Step 6: Create `WorkdeckHelper/SleepSessionTracker.swift`**

```swift
import Foundation
import Synchronization

/// Remembers which client connections turned sleep off, so sleep is restored when the last one disconnects.
final class SleepSessionTracker: Sendable {
    private let holders = Mutex<Set<ObjectIdentifier>>([])

    func clientDidSet(_ client: ObjectIdentifier, sleepDisabled: Bool) {
        holders.withLock { holders in
            if sleepDisabled {
                holders.insert(client)
            } else {
                // Re-enabling sleep is system-wide, so no client holds it disabled anymore.
                holders.removeAll()
            }
        }
    }

    /// Returns `true` when the departing client was the last one holding sleep disabled.
    func clientDidDisconnect(_ client: ObjectIdentifier) -> Bool {
        holders.withLock { holders in
            holders.remove(client) != nil && holders.isEmpty
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: the same command as Step 3.
Expected: `** TEST SUCCEEDED **`, no `recorded an issue` lines.

- [ ] **Step 8: Commit**

```bash
git add WorkdeckHelper WorkdeckTests
git commit -m "Add pmset-backed power settings and sleep session tracking to helper"
```

---

### Task 4: Helper XPC service and listener

**Files:**
- Create: `WorkdeckHelper/HelperService.swift`
- Create: `WorkdeckHelper/HelperListenerDelegate.swift`
- Replace: `WorkdeckHelper/main.swift`

**Interfaces:**
- Consumes: `PowerSettings`, `ProcessCommandRunner`, `SleepSessionTracker` (Task 3); `HelperProtocol`, `HelperConstants` (Task 1).
- Produces: a helper binary that resets `disablesleep 0` on start, listens on `com.appcreators.workdeck.helper`, accepts only clients matching `HelperConstants.clientRequirement`, and restores sleep when the last client that disabled it disconnects.

These files are excluded from the test target (they need `Shared/`), so this task is verified by building and by the existing suite. Root-level behavior is verified manually in Task 12.

- [ ] **Step 1: Create `WorkdeckHelper/HelperService.swift`**

```swift
import Foundation

/// Object exported to a single client connection.
final class HelperService: NSObject, HelperProtocol {
    private let power: PowerSettings
    private let tracker: SleepSessionTracker
    private let clientID: ObjectIdentifier

    init(power: PowerSettings, tracker: SleepSessionTracker, clientID: ObjectIdentifier) {
        self.power = power
        self.tracker = tracker
        self.clientID = clientID
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        do {
            try power.setSleepDisabled(disabled)
            tracker.clientDidSet(clientID, sleepDisabled: disabled)
            reply(nil)
        } catch {
            reply(Self.xpcError(error))
        }
    }

    func isSleepDisabled(reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        do {
            reply(try power.isSleepDisabled(), nil)
        } catch {
            reply(false, Self.xpcError(error))
        }
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.version(of: .main))
    }

    /// Only plain strings cross the XPC boundary in errors.
    private static func xpcError(_ error: any Error) -> NSError {
        NSError(
            domain: HelperConstants.errorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]
        )
    }
}
```

- [ ] **Step 2: Create `WorkdeckHelper/HelperListenerDelegate.swift`**

```swift
import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let power: PowerSettings
    private let tracker = SleepSessionTracker()

    init(power: PowerSettings) {
        self.power = power
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let clientID = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperService(power: power, tracker: tracker, clientID: clientID)
        connection.invalidationHandler = { [power, tracker] in
            // The client quit or crashed while holding sleep disabled: restore normal sleep.
            if tracker.clientDidDisconnect(clientID) {
                try? power.setSleepDisabled(false)
            }
        }
        connection.resume()
        return true
    }
}
```

- [ ] **Step 3: Replace `WorkdeckHelper/main.swift`**

```swift
import Foundation

let power = PowerSettings(runner: ProcessCommandRunner())

// Launchd starts the helper at boot and after a crash; no client can be holding sleep disabled then.
try? power.setSleepDisabled(false)

let delegate = HelperListenerDelegate(power: power)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperConstants.clientRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
```

- [ ] **Step 4: Build and run the full suite**

Run: the test command (no `-only-testing`).
Expected: `** TEST SUCCEEDED **`; no compiler warnings in `WorkdeckHelper/` (check with `xcodebuild -scheme Workdeck -destination 'platform=macOS' build 2>&1 | grep "warning:" | grep -v appintents` → no output).

- [ ] **Step 5: Commit**

```bash
git add WorkdeckHelper
git commit -m "Add helper XPC listener that restores sleep on start and client disconnect"
```

---

### Task 5: Safeguard policy

**Files:**
- Create: `Workdeck/Features/ClosedLidMode/SafeguardPolicy.swift`
- Test: `WorkdeckTests/SafeguardPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (all `nonisolated`, so they are usable from nonisolated test arguments and any actor):
  - `struct PowerSnapshot: Equatable, Sendable { var isOnBattery: Bool; var batteryPercent: Int? }`
  - `enum CutoffReason: Equatable, Sendable { case lowBattery(threshold: Int), thermal, helperRestarted }`
  - `enum SafeguardDecision: Equatable, Sendable { case allow, cutoff(CutoffReason) }`
  - `enum SafeguardPolicy { static func evaluate(power: PowerSnapshot, thermal: ProcessInfo.ThermalState, threshold: Int) -> SafeguardDecision }`

- [ ] **Step 1: Write the failing test `WorkdeckTests/SafeguardPolicyTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

struct SafeguardPolicyTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let power: PowerSnapshot
        let thermal: ProcessInfo.ThermalState
        let threshold: Int
        let expected: SafeguardDecision
        var testDescription: String { "\(power) \(thermal.rawValue) <\(threshold)% → \(expected)" }
    }

    static let cases: [Case] = [
        Case(power: .init(isOnBattery: false, batteryPercent: 5), thermal: .nominal, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: true, batteryPercent: 50), thermal: .nominal, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: true, batteryPercent: 19), thermal: .nominal, threshold: 20, expected: .cutoff(.lowBattery(threshold: 20))),
        Case(power: .init(isOnBattery: true, batteryPercent: 20), thermal: .nominal, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: true, batteryPercent: nil), thermal: .nominal, threshold: 50, expected: .allow),
        Case(power: .init(isOnBattery: false, batteryPercent: nil), thermal: .fair, threshold: 20, expected: .allow),
        Case(power: .init(isOnBattery: false, batteryPercent: 90), thermal: .serious, threshold: 20, expected: .cutoff(.thermal)),
        Case(power: .init(isOnBattery: true, batteryPercent: 5), thermal: .critical, threshold: 20, expected: .cutoff(.thermal)),
    ]

    @Test(arguments: cases)
    func evaluate(_ testCase: Case) {
        let decision = SafeguardPolicy.evaluate(power: testCase.power, thermal: testCase.thermal, threshold: testCase.threshold)
        #expect(decision == testCase.expected)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/SafeguardPolicyTests`
Expected: build fails with `cannot find type 'PowerSnapshot' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClosedLidMode/SafeguardPolicy.swift`**

```swift
import Foundation

nonisolated struct PowerSnapshot: Equatable, Sendable {
    var isOnBattery: Bool
    /// `nil` on Macs without a battery.
    var batteryPercent: Int?
}

nonisolated enum CutoffReason: Equatable, Sendable {
    case lowBattery(threshold: Int)
    case thermal
    case helperRestarted
}

nonisolated enum SafeguardDecision: Equatable, Sendable {
    case allow
    case cutoff(CutoffReason)
}

/// Decides whether Closed-Lid Mode may be (or stay) on. Used both before enabling and while active.
nonisolated enum SafeguardPolicy {
    static func evaluate(
        power: PowerSnapshot,
        thermal: ProcessInfo.ThermalState,
        threshold: Int
    ) -> SafeguardDecision {
        if thermal == .serious || thermal == .critical {
            return .cutoff(.thermal)
        }
        if power.isOnBattery, let percent = power.batteryPercent, percent < threshold {
            return .cutoff(.lowBattery(threshold: threshold))
        }
        return .allow
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same as Step 2.
Expected: `Test run with 1 test in 1 suite passed` (8 argument cases), `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClosedLidMode/SafeguardPolicy.swift WorkdeckTests/SafeguardPolicyTests.swift
git commit -m "Add battery and thermal safeguard policy"
```

---

### Task 6: App settings

**Files:**
- Create: `Workdeck/Core/AppSettings.swift`
- Test: `WorkdeckTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `@Observable final class AppSettings` (MainActor) with `static let thresholdRange: ClosedRange<Int>` (10...50), `thresholdStep` (5), `defaultThreshold` (20), `thresholdOptions: [Int]`; `init(defaults: UserDefaults = .standard)`; `var batteryThreshold: Int` (normalized and persisted under key `"batteryThreshold"` on every set); `private(set) var launchAtLogin: Bool`; `func setLaunchAtLogin(_ enabled: Bool)`; `static func normalizedThreshold(_ value: Int) -> Int`.

- [ ] **Step 1: Write the failing test `WorkdeckTests/AppSettingsTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct AppSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "WorkdeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsToTwentyPercent() {
        #expect(AppSettings(defaults: makeDefaults()).batteryThreshold == 20)
    }

    @Test func persistsThreshold() {
        let defaults = makeDefaults()
        AppSettings(defaults: defaults).batteryThreshold = 35
        #expect(AppSettings(defaults: defaults).batteryThreshold == 35)
    }

    @Test func normalizesOutOfRangeStoredValue() {
        let defaults = makeDefaults()
        defaults.set(90, forKey: "batteryThreshold")
        #expect(AppSettings(defaults: defaults).batteryThreshold == 50)
    }

    @Test(arguments: [(3, 10), (10, 10), (22, 20), (23, 25), (50, 50), (99, 50)])
    func normalizedThreshold(input: Int, expected: Int) {
        #expect(AppSettings.normalizedThreshold(input) == expected)
    }

    @Test func offersTenToFiftyInStepsOfFive() {
        #expect(AppSettings.thresholdOptions == [10, 15, 20, 25, 30, 35, 40, 45, 50])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/AppSettingsTests`
Expected: build fails with `cannot find 'AppSettings' in scope`.

- [ ] **Step 3: Create `Workdeck/Core/AppSettings.swift`**

```swift
import Foundation
import Observation
import ServiceManagement

@Observable
final class AppSettings {
    static let thresholdRange = 10...50
    static let thresholdStep = 5
    static let defaultThreshold = 20
    static let thresholdOptions = Array(stride(from: thresholdRange.lowerBound, through: thresholdRange.upperBound, by: thresholdStep))

    private enum Keys {
        static let batteryThreshold = "batteryThreshold"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Battery percentage below which Closed-Lid Mode turns itself off while on battery.
    var batteryThreshold: Int {
        didSet {
            let normalized = Self.normalizedThreshold(batteryThreshold)
            if normalized != batteryThreshold {
                batteryThreshold = normalized
            }
            defaults.set(batteryThreshold, forKey: Keys.batteryThreshold)
        }
    }

    private(set) var launchAtLogin: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Keys.batteryThreshold) as? Int
        batteryThreshold = Self.normalizedThreshold(stored ?? Self.defaultThreshold)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The status below reflects what actually happened.
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Clamps to `thresholdRange` and rounds to the nearest `thresholdStep`.
    static func normalizedThreshold(_ value: Int) -> Int {
        let clamped = min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
        let steps = (Double(clamped) / Double(thresholdStep)).rounded()
        return Int(steps) * thresholdStep
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`, no `recorded an issue` lines.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Core/AppSettings.swift WorkdeckTests/AppSettingsTests.swift
git commit -m "Add persisted battery threshold and launch-at-login settings"
```

---

### Task 7: XPC helper client

**Files:**
- Create: `Workdeck/Core/HelperClient.swift`
- Test: `WorkdeckTests/HelperClientTests.swift`

**Interfaces:**
- Consumes: `HelperProtocol`, `HelperConstants` (Task 1).
- Produces:
  - `enum HelperClientError: LocalizedError, Equatable { case timeout, connectionFailed(String), helperFailed(String) }`
  - `protocol HelperClientProtocol: AnyObject` (MainActor) with `var onInterruption: (() -> Void)? { get set }`, `func setSleepDisabled(_ disabled: Bool) async throws`, `func isSleepDisabled() async throws -> Bool`, `func version() async throws -> String`, `func restoreSleepSynchronously()`.
  - `final class HelperClient: HelperClientProtocol` with `init(timeout: TimeInterval = 5, makeConnection: @escaping () -> NSXPCConnection = HelperClient.privilegedConnection)` and `nonisolated static func privilegedConnection() -> NSXPCConnection`.

Background: XPC reply blocks and error handlers run on background queues. Every closure handed to XPC is `@Sendable` (so it does not inherit `MainActor`), and `ResumeOnce` is explicitly `nonisolated`; without that, Swift 6 inserts main-actor checks that crash at runtime. The tests run a real `NSXPCListener.anonymous()` in-process, so they exercise actual XPC encoding and threading.

- [ ] **Step 1: Write the failing test `WorkdeckTests/HelperClientTests.swift`**

```swift
import Foundation
import Synchronization
import Testing
@testable import Workdeck

/// In-process stand-in for the privileged helper, served over an anonymous XPC listener.
final class StubHelper: NSObject, Workdeck.HelperProtocol, NSXPCListenerDelegate {
    struct State {
        var sleepDisabled = false
        var setError: NSError?
        var respond = true
        var versionString = "1.0 (1)"
    }

    let state = Mutex(State())
    let listener = NSXPCListener.anonymous()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    @MainActor func makeClient(timeout: TimeInterval = 5) -> HelperClient {
        let endpoint = listener.endpoint
        return HelperClient(timeout: timeout) { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: Workdeck.HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        let (respond, error) = state.withLock { state in
            if state.setError == nil { state.sleepDisabled = disabled }
            return (state.respond, state.setError)
        }
        if respond { reply(error) }
    }

    func isSleepDisabled(reply: @escaping @Sendable (Bool, NSError?) -> Void) {
        let (respond, value) = state.withLock { ($0.respond, $0.sleepDisabled) }
        if respond { reply(value, nil) }
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        let (respond, value) = state.withLock { ($0.respond, $0.versionString) }
        if respond { reply(value) }
    }
}

@MainActor
struct HelperClientTests {
    @Test func setsAndReadsSleepDisabled() async throws {
        let stub = StubHelper()
        let client = stub.makeClient()
        try await client.setSleepDisabled(true)
        #expect(try await client.isSleepDisabled())
        try await client.setSleepDisabled(false)
        #expect(try await client.isSleepDisabled() == false)
    }

    @Test func returnsHelperVersion() async throws {
        let stub = StubHelper()
        stub.state.withLock { $0.versionString = "2.0 (7)" }
        #expect(try await stub.makeClient().version() == "2.0 (7)")
    }

    @Test func surfacesHelperError() async {
        let stub = StubHelper()
        stub.state.withLock {
            $0.setError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "pmset failed"])
        }
        await #expect(throws: HelperClientError.helperFailed("pmset failed")) {
            try await stub.makeClient().setSleepDisabled(true)
        }
    }

    @Test func timesOutWhenHelperNeverReplies() async {
        let stub = StubHelper()
        stub.state.withLock { $0.respond = false }
        await #expect(throws: HelperClientError.timeout) {
            try await stub.makeClient(timeout: 0.2).isSleepDisabled()
        }
    }

    @Test func lateReplyAfterTimeoutIsIgnored() async throws {
        let stub = StubHelper()
        let client = stub.makeClient(timeout: 0.2)
        stub.state.withLock { $0.respond = false }
        await #expect(throws: HelperClientError.timeout) {
            try await client.isSleepDisabled()
        }
        stub.state.withLock { $0.respond = true }
        // A second call on the same connection must still work and must not double-resume.
        #expect(try await client.isSleepDisabled() == false)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/HelperClientTests`
Expected: build fails with `cannot find type 'HelperClient' in scope`.

- [ ] **Step 3: Create `Workdeck/Core/HelperClient.swift`**

```swift
import Foundation
import Synchronization

enum HelperClientError: LocalizedError, Equatable {
    case timeout
    case connectionFailed(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: "The helper did not respond in time."
        case let .connectionFailed(message): "Couldn't connect to the helper: \(message)"
        case let .helperFailed(message): message
        }
    }
}

/// Async interface to the privileged helper.
protocol HelperClientProtocol: AnyObject {
    /// Called on the main actor when the helper process went away while connected.
    var onInterruption: (() -> Void)? { get set }
    func setSleepDisabled(_ disabled: Bool) async throws
    func isSleepDisabled() async throws -> Bool
    func version() async throws -> String
    /// Blocking variant for `applicationWillTerminate`, where awaiting is not possible.
    func restoreSleepSynchronously()
}

final class HelperClient: HelperClientProtocol {
    var onInterruption: (() -> Void)?

    private let makeConnection: () -> NSXPCConnection
    private let timeout: TimeInterval
    private var connection: NSXPCConnection?

    init(timeout: TimeInterval = 5, makeConnection: @escaping () -> NSXPCConnection = HelperClient.privilegedConnection) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }

    nonisolated static func privilegedConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        return connection
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        try await call { helper, done in
            helper.setSleepDisabled(disabled) { error in
                done(error.map { .failure(HelperClientError.helperFailed($0.localizedDescription)) } ?? .success(()))
            }
        }
    }

    func isSleepDisabled() async throws -> Bool {
        try await call { helper, done in
            helper.isSleepDisabled { disabled, error in
                done(error.map { .failure(HelperClientError.helperFailed($0.localizedDescription)) } ?? .success(disabled))
            }
        }
    }

    func version() async throws -> String {
        try await call { helper, done in
            helper.version { done(.success($0)) }
        }
    }

    func restoreSleepSynchronously() {
        let proxy = activeConnection().synchronousRemoteObjectProxyWithErrorHandler { _ in }
        (proxy as? any HelperProtocol)?.setSleepDisabled(false) { _ in }
    }

    private func call<T: Sendable>(
        _ body: (any HelperProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = activeConnection()
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(HelperClientError.connectionFailed(error.localizedDescription)))
            }
            guard let helper = proxy as? any HelperProtocol else {
                once.resume(with: .failure(HelperClientError.connectionFailed("Unexpected proxy type")))
                return
            }
            body(helper) { once.resume(with: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(with: .failure(HelperClientError.timeout))
            }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection {
            return connection
        }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.onInterruption?() }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// Resumes a continuation at most once; later reply, error, or timeout callbacks are ignored.
nonisolated private final class ResumeOnce<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same as Step 2.
Expected: `Test run with 5 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Core/HelperClient.swift WorkdeckTests/HelperClientTests.swift
git commit -m "Add async XPC helper client with timeout and single-resume guarantee"
```

---

### Task 8: System adapters — helper installer and power/thermal monitors

**Files:**
- Create: `Workdeck/Core/HelperInstaller.swift`
- Create: `Workdeck/Features/ClosedLidMode/PowerSourceMonitor.swift`
- Create: `Workdeck/Features/ClosedLidMode/ThermalMonitor.swift`

**Interfaces:**
- Consumes: `HelperConstants` (Task 1), `PowerSnapshot` (Task 5).
- Produces:
  - `enum HelperStatus: Equatable { case notRegistered, requiresApproval, enabled, unavailable(String) }`
  - `protocol HelperInstallerProtocol: AnyObject { var status: HelperStatus { get }; func register() throws; func unregister() async throws; func openApprovalSettings() }` and `final class HelperInstaller`.
  - `protocol PowerSourceMonitoring: AnyObject { var current: PowerSnapshot { get }; var onChange: ((PowerSnapshot) -> Void)? { get set } }` and `final class PowerSourceMonitor` with `static func readSnapshot() -> PowerSnapshot`.
  - `protocol ThermalMonitoring: AnyObject { var current: ProcessInfo.ThermalState { get }; var onChange: ((ProcessInfo.ThermalState) -> Void)? { get set } }` and `final class ThermalMonitor`.

These are thin wrappers over `SMAppService`, IOKit, and `ProcessInfo`; their protocols are what the controller is tested against (Task 9). They are verified by building and by a quick snapshot read.

- [ ] **Step 1: Create `Workdeck/Core/HelperInstaller.swift`**

```swift
import Foundation
import ServiceManagement

enum HelperStatus: Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case unavailable(String)
}

protocol HelperInstallerProtocol: AnyObject {
    var status: HelperStatus { get }
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
}

/// Registers the bundled launch daemon with `SMAppService`.
final class HelperInstaller: HelperInstallerProtocol {
    private let service = SMAppService.daemon(plistName: HelperConstants.launchDaemonPlistName)

    var status: HelperStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .unavailable("The helper is missing from the app bundle.")
        @unknown default: .unavailable("Unknown helper status.")
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
```

- [ ] **Step 2: Create `Workdeck/Features/ClosedLidMode/PowerSourceMonitor.swift`**

```swift
import Foundation
import IOKit.ps

protocol PowerSourceMonitoring: AnyObject {
    var current: PowerSnapshot { get }
    var onChange: ((PowerSnapshot) -> Void)? { get set }
}

/// Publishes battery level and power source changes from IOKit.
final class PowerSourceMonitor: PowerSourceMonitoring {
    var onChange: ((PowerSnapshot) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.onChange?(monitor.current)
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    isolated deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    var current: PowerSnapshot {
        Self.readSnapshot()
    }

    static func readSnapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(isOnBattery: false, batteryPercent: nil)
        }
        let providingType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let isOnBattery = providingType == kIOPSBatteryPowerValue
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0
            else { continue }
            return PowerSnapshot(isOnBattery: isOnBattery, batteryPercent: capacity * 100 / maxCapacity)
        }
        return PowerSnapshot(isOnBattery: isOnBattery, batteryPercent: nil)
    }
}
```

- [ ] **Step 3: Create `Workdeck/Features/ClosedLidMode/ThermalMonitor.swift`**

```swift
import Foundation

protocol ThermalMonitoring: AnyObject {
    var current: ProcessInfo.ThermalState { get }
    var onChange: ((ProcessInfo.ThermalState) -> Void)? { get set }
}

final class ThermalMonitor: ThermalMonitoring {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?(self.current)
            }
        }
    }

    var current: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
```

- [ ] **Step 4: Add a smoke test for the power snapshot reader to `WorkdeckTests/SafeguardPolicyTests.swift`**

Append inside `struct SafeguardPolicyTests`:

```swift
    @Test @MainActor func readsRealPowerSnapshot() {
        let snapshot = PowerSourceMonitor.readSnapshot()
        if let percent = snapshot.batteryPercent {
            #expect((0...100).contains(percent))
        }
    }
```

- [ ] **Step 5: Run the full suite**

Run: the test command.
Expected: `** TEST SUCCEEDED **`, no warnings from the new files.

- [ ] **Step 6: Commit**

```bash
git add Workdeck WorkdeckTests
git commit -m "Add SMAppService installer and IOKit power and thermal monitors"
```

---

### Task 9: Closed-Lid Mode controller

**Files:**
- Create: `Workdeck/Features/ClosedLidMode/LidSleepController.swift`
- Create: `WorkdeckTests/Fakes/Fakes.swift`
- Test: `WorkdeckTests/LidSleepControllerTests.swift`

**Interfaces:**
- Consumes: `HelperClientProtocol` (Task 7), `HelperInstallerProtocol`, `HelperStatus`, `PowerSourceMonitoring`, `ThermalMonitoring` (Task 8), `SafeguardPolicy`, `PowerSnapshot`, `CutoffReason` (Task 5), `AppSettings` (Task 6).
- Produces: `@Observable final class LidSleepController` with
  - `enum Notice: Equatable { case cutoff(CutoffReason), refused(CutoffReason) }`
  - read-only state: `helperStatus: HelperStatus`, `isActive: Bool`, `isBusy: Bool`, `notice: Notice?`, `lastError: String?`, `power: PowerSnapshot`, `threshold: Int`, `canToggle: Bool`, `safeguardTask: Task<Void, Never>?`, `interruptionTask: Task<Void, Never>?`
  - `init(helper:installer:powerMonitor:thermalMonitor:settings:appVersion:)`
  - `func setEnabled(_:) async`, `func enable() async`, `func disable(reason: CutoffReason?) async`, `func refresh() async`, `func scheduleSafeguardCheck()`, `func openApprovalSettings()`, `func prepareForTermination()`

Behavior (spec §6): enabling evaluates safeguards first (refusal → `notice = .refused`), then registers the helper if needed (pending approval is not an error), checks the helper version once per connection and reinstalls a stale helper, then disables sleep. Monitor events and threshold changes re-run the policy while active; a cutoff disables sleep and sets `notice = .cutoff`. A helper interruption marks the mode off and resyncs; if it was on, `notice = .cutoff(.helperRestarted)`. `prepareForTermination` restores sleep synchronously when active.

- [ ] **Step 1: Create the fakes `WorkdeckTests/Fakes/Fakes.swift`**

```swift
import Foundation
@testable import Workdeck

@MainActor
final class FakeHelperClient: HelperClientProtocol {
    var onInterruption: (() -> Void)?
    var sleepDisabled = false
    var versionString = "1.0 (1)"
    var setError: (any Error)?
    var readError: (any Error)?
    private(set) var setCalls: [Bool] = []
    private(set) var synchronousRestoreCount = 0

    func setSleepDisabled(_ disabled: Bool) async throws {
        setCalls.append(disabled)
        if let setError { throw setError }
        sleepDisabled = disabled
    }

    func isSleepDisabled() async throws -> Bool {
        if let readError { throw readError }
        return sleepDisabled
    }

    func version() async throws -> String {
        versionString
    }

    func restoreSleepSynchronously() {
        synchronousRestoreCount += 1
        sleepDisabled = false
    }

    /// Simulates the helper process crashing and launchd relaunching it.
    func simulateRestart() {
        sleepDisabled = false
        onInterruption?()
    }
}

@MainActor
final class FakeHelperInstaller: HelperInstallerProtocol {
    var status: HelperStatus
    /// Status the installer moves to when `register()` is called.
    var statusAfterRegister: HelperStatus = .enabled
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: HelperStatus = .enabled) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        status = statusAfterRegister
        if status == .requiresApproval {
            throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
        }
    }

    func unregister() async throws {
        unregisterCount += 1
        status = .notRegistered
    }

    func openApprovalSettings() {
        openSettingsCount += 1
    }
}

@MainActor
final class FakePowerSourceMonitor: PowerSourceMonitoring {
    var current: PowerSnapshot
    var onChange: ((PowerSnapshot) -> Void)?

    init(_ current: PowerSnapshot = PowerSnapshot(isOnBattery: false, batteryPercent: 80)) {
        self.current = current
    }

    func emit(_ snapshot: PowerSnapshot) {
        current = snapshot
        onChange?(snapshot)
    }
}

@MainActor
final class FakeThermalMonitor: ThermalMonitoring {
    var current: ProcessInfo.ThermalState = .nominal
    var onChange: ((ProcessInfo.ThermalState) -> Void)?

    func emit(_ state: ProcessInfo.ThermalState) {
        current = state
        onChange?(state)
    }
}
```

- [ ] **Step 2: Write the failing test `WorkdeckTests/LidSleepControllerTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct LidSleepControllerTests {
    let helper = FakeHelperClient()
    let installer = FakeHelperInstaller()
    let power = FakePowerSourceMonitor()
    let thermal = FakeThermalMonitor()
    let settings: AppSettings

    init() {
        let suite = "WorkdeckTests.\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    }

    func makeController(appVersion: String = "1.0 (1)") -> LidSleepController {
        LidSleepController(
            helper: helper,
            installer: installer,
            powerMonitor: power,
            thermalMonitor: thermal,
            settings: settings,
            appVersion: appVersion
        )
    }

    @Test func enableTurnsSleepOff() async {
        let controller = makeController()
        await controller.enable()
        #expect(controller.isActive)
        #expect(helper.sleepDisabled)
        #expect(controller.notice == nil)
    }

    @Test func enableRefusedOnLowBattery() async {
        power.current = PowerSnapshot(isOnBattery: true, batteryPercent: 10)
        let controller = makeController()
        await controller.enable()
        #expect(!controller.isActive)
        #expect(helper.setCalls.isEmpty)
        #expect(controller.notice == .refused(.lowBattery(threshold: 20)))
    }

    @Test func enableRefusedWhenHot() async {
        thermal.current = .serious
        let controller = makeController()
        await controller.enable()
        #expect(!controller.isActive)
        #expect(controller.notice == .refused(.thermal))
    }

    @Test func enableRegistersHelperAndWaitsForApproval() async {
        installer.status = .notRegistered
        installer.statusAfterRegister = .requiresApproval
        let controller = makeController()
        await controller.enable()
        #expect(installer.registerCount == 1)
        #expect(controller.helperStatus == .requiresApproval)
        #expect(controller.lastError == nil)
        #expect(!controller.isActive)
        #expect(!controller.canToggle)
    }

    @Test func refreshPicksUpApprovalGrantedInSystemSettings() async {
        installer.status = .requiresApproval
        let controller = makeController()
        installer.status = .enabled
        await controller.refresh()
        #expect(controller.helperStatus == .enabled)
        #expect(controller.canToggle)
    }

    @Test func refreshReflectsRealSystemState() async {
        helper.sleepDisabled = true
        let controller = makeController()
        await controller.refresh()
        #expect(controller.isActive)
    }

    @Test func helperErrorIsSurfacedAndControllerStaysUsable() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        helper.setError = Boom()
        let controller = makeController()
        await controller.enable()
        #expect(!controller.isActive)
        #expect(controller.lastError == "boom")
        #expect(!controller.isBusy)
        #expect(controller.canToggle)
    }

    @Test func lowBatteryWhileActiveTurnsModeOff() async {
        let controller = makeController()
        await controller.enable()
        power.emit(PowerSnapshot(isOnBattery: true, batteryPercent: 15))
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(!helper.sleepDisabled)
        #expect(controller.notice == .cutoff(.lowBattery(threshold: 20)))
    }

    @Test func heatWhileActiveTurnsModeOff() async {
        let controller = makeController()
        await controller.enable()
        thermal.emit(.critical)
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.thermal))
    }

    @Test func raisingThresholdAboveChargeTurnsModeOff() async {
        power.current = PowerSnapshot(isOnBattery: true, batteryPercent: 30)
        let controller = makeController()
        await controller.enable()
        #expect(controller.isActive)
        settings.batteryThreshold = 40
        controller.scheduleSafeguardCheck()
        await controller.safeguardTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.lowBattery(threshold: 40)))
    }

    @Test func userDisableClearsNotice() async {
        let controller = makeController()
        await controller.enable()
        await controller.disable(reason: nil)
        #expect(!controller.isActive)
        #expect(controller.notice == nil)
        #expect(helper.setCalls == [true, false])
    }

    @Test func reEnablingClearsPreviousCutoff() async {
        let controller = makeController()
        await controller.enable()
        thermal.emit(.serious)
        await controller.safeguardTask?.value
        thermal.current = .nominal
        await controller.enable()
        #expect(controller.isActive)
        #expect(controller.notice == nil)
    }

    @Test func helperRestartTurnsModeOffWithNotice() async {
        let controller = makeController()
        await controller.enable()
        helper.simulateRestart()
        await controller.interruptionTask?.value
        #expect(!controller.isActive)
        #expect(controller.notice == .cutoff(.helperRestarted))
    }

    @Test func staleHelperIsReinstalled() async {
        helper.versionString = "0.9 (1)"
        let controller = makeController(appVersion: "1.0 (1)")
        await controller.enable()
        #expect(installer.unregisterCount == 1)
        #expect(installer.registerCount == 1)
        #expect(controller.isActive)
    }

    @Test func terminationRestoresSleepWhenActive() async {
        let controller = makeController()
        await controller.enable()
        controller.prepareForTermination()
        #expect(helper.synchronousRestoreCount == 1)
    }

    @Test func terminationDoesNothingWhenInactive() {
        let controller = makeController()
        controller.prepareForTermination()
        #expect(helper.synchronousRestoreCount == 0)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/LidSleepControllerTests`
Expected: build fails with `cannot find 'LidSleepController' in scope`.

- [ ] **Step 4: Create `Workdeck/Features/ClosedLidMode/LidSleepController.swift`**

```swift
import Foundation
import Observation

/// Owns Closed-Lid Mode: talks to the helper, applies safeguards, and exposes state to the UI.
@Observable
final class LidSleepController {
    enum Notice: Equatable {
        /// A safeguard or helper restart turned the mode off.
        case cutoff(CutoffReason)
        /// Enabling was refused because a safeguard condition already holds.
        case refused(CutoffReason)
    }

    private(set) var helperStatus: HelperStatus
    private(set) var isActive = false
    private(set) var isBusy = false
    private(set) var notice: Notice?
    private(set) var lastError: String?
    private(set) var power: PowerSnapshot

    /// Latest safeguard check started by a monitor event; exposed so tests can await it.
    @ObservationIgnored private(set) var safeguardTask: Task<Void, Never>?
    /// Latest resync started by a helper interruption; exposed so tests can await it.
    @ObservationIgnored private(set) var interruptionTask: Task<Void, Never>?

    @ObservationIgnored private let helper: any HelperClientProtocol
    @ObservationIgnored private let installer: any HelperInstallerProtocol
    @ObservationIgnored private let powerMonitor: any PowerSourceMonitoring
    @ObservationIgnored private let thermalMonitor: any ThermalMonitoring
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var helperVersionChecked = false

    init(
        helper: any HelperClientProtocol,
        installer: any HelperInstallerProtocol,
        powerMonitor: any PowerSourceMonitoring,
        thermalMonitor: any ThermalMonitoring,
        settings: AppSettings,
        appVersion: String
    ) {
        self.helper = helper
        self.installer = installer
        self.powerMonitor = powerMonitor
        self.thermalMonitor = thermalMonitor
        self.settings = settings
        self.appVersion = appVersion
        helperStatus = installer.status
        power = powerMonitor.current

        powerMonitor.onChange = { [weak self] snapshot in
            self?.power = snapshot
            self?.scheduleSafeguardCheck()
        }
        thermalMonitor.onChange = { [weak self] _ in
            self?.scheduleSafeguardCheck()
        }
        helper.onInterruption = { [weak self] in
            self?.handleHelperInterruption()
        }
    }

    var threshold: Int {
        settings.batteryThreshold
    }

    var canToggle: Bool {
        !isBusy && (helperStatus == .enabled || helperStatus == .notRegistered)
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            await enable()
        } else {
            await disable(reason: nil)
        }
    }

    func enable() async {
        guard !isBusy, !isActive else { return }
        isBusy = true
        defer { isBusy = false }
        notice = nil
        lastError = nil

        power = powerMonitor.current
        let decision = SafeguardPolicy.evaluate(power: power, thermal: thermalMonitor.current, threshold: threshold)
        if case let .cutoff(reason) = decision {
            notice = .refused(reason)
            return
        }
        guard await prepareHelper(registerIfNeeded: true) else { return }

        do {
            try await helper.setSleepDisabled(true)
            isActive = true
        } catch {
            lastError = error.localizedDescription
            await syncState()
        }
    }

    /// Turns the mode off. `reason` is set when a safeguard, not the user, triggered it.
    func disable(reason: CutoffReason?) async {
        guard isActive, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil

        do {
            try await helper.setSleepDisabled(false)
            isActive = false
            notice = reason.map(Notice.cutoff)
        } catch {
            lastError = error.localizedDescription
            await syncState()
        }
    }

    /// Re-reads helper status and the real system setting. Called on launch and whenever the popover opens.
    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        power = powerMonitor.current
        _ = await prepareHelper(registerIfNeeded: false)
        await syncState()
    }

    /// Re-checks safeguards, e.g. after the battery threshold changed.
    func scheduleSafeguardCheck() {
        safeguardTask = Task { await evaluateSafeguards() }
    }

    func openApprovalSettings() {
        installer.openApprovalSettings()
    }

    /// Restores sleep before the app exits; the helper also does this when the connection drops.
    func prepareForTermination() {
        if isActive {
            helper.restoreSleepSynchronously()
        }
    }

    private func evaluateSafeguards() async {
        guard isActive else { return }
        let decision = SafeguardPolicy.evaluate(power: power, thermal: thermalMonitor.current, threshold: threshold)
        if case let .cutoff(reason) = decision {
            await disable(reason: reason)
        }
    }

    private func syncState() async {
        helperStatus = installer.status
        guard helperStatus == .enabled else {
            isActive = false
            return
        }
        do {
            isActive = try await helper.isSleepDisabled()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Registers the helper if requested and replaces it when its version differs from the app's.
    private func prepareHelper(registerIfNeeded: Bool) async -> Bool {
        helperStatus = installer.status
        if helperStatus != .enabled, registerIfNeeded {
            do {
                try installer.register()
            } catch {
                // Registration "fails" while approval is pending; only surface other failures.
                if installer.status == .notRegistered {
                    lastError = error.localizedDescription
                }
            }
            helperStatus = installer.status
        }
        guard helperStatus == .enabled else { return false }
        guard !helperVersionChecked else { return true }

        do {
            let helperVersion = try await helper.version()
            helperVersionChecked = true
            if helperVersion != appVersion {
                try? await installer.unregister()
                try? installer.register()
                helperStatus = installer.status
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
        return helperStatus == .enabled
    }

    private func handleHelperInterruption() {
        let wasActive = isActive
        isActive = false
        helperVersionChecked = false
        // The relaunched helper resets sleep on startup; resync to confirm.
        interruptionTask = Task {
            await syncState()
            if wasActive, !isActive {
                notice = .cutoff(.helperRestarted)
            }
        }
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: same as Step 3.
Expected: `Test run with 16 tests in 1 suite passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Workdeck/Features/ClosedLidMode/LidSleepController.swift WorkdeckTests
git commit -m "Add Closed-Lid Mode controller with safeguards and helper lifecycle handling"
```

---

### Task 10: Subtitle text mapping

**Files:**
- Create: `Workdeck/Features/ClosedLidMode/ClosedLidModeSubtitle.swift`
- Test: `WorkdeckTests/ClosedLidModeSubtitleTests.swift`

**Interfaces:**
- Consumes: `HelperStatus` (Task 8), `PowerSnapshot`, `CutoffReason` (Task 5), `LidSleepController.Notice` (Task 9).
- Produces: `struct ClosedLidModeSubtitle: Equatable { let text: String; let isError: Bool; static func make(helperStatus:isActive:power:threshold:notice:lastError:) -> ClosedLidModeSubtitle }`.

Precedence: `lastError` → helper approval/unavailable → active text → notice → default off text. Strings come from spec §5.3.

- [ ] **Step 1: Write the failing test `WorkdeckTests/ClosedLidModeSubtitleTests.swift`**

```swift
import Foundation
import Testing
@testable import Workdeck

@MainActor
struct ClosedLidModeSubtitleTests {
    private let adapter = PowerSnapshot(isOnBattery: false, batteryPercent: 80)
    private let battery = PowerSnapshot(isOnBattery: true, batteryPercent: 80)

    private func make(
        status: HelperStatus = .enabled,
        active: Bool = false,
        power: PowerSnapshot? = nil,
        notice: LidSleepController.Notice? = nil,
        error: String? = nil
    ) -> ClosedLidModeSubtitle {
        .make(helperStatus: status, isActive: active, power: power ?? adapter, threshold: 20, notice: notice, lastError: error)
    }

    @Test func off() {
        #expect(make() == .init(text: "Mac sleeps normally when the lid is closed", isError: false))
    }

    @Test func notRegisteredLooksLikeOff() {
        #expect(make(status: .notRegistered).text == "Mac sleeps normally when the lid is closed")
    }

    @Test func onWithAdapter() {
        #expect(make(active: true).text == "Mac won't sleep when the lid is closed")
    }

    @Test func onWithBatteryMentionsThreshold() {
        #expect(make(active: true, power: battery).text == "Mac won't sleep when the lid is closed · Turns off below 20% battery")
    }

    @Test func requiresApproval() {
        #expect(make(status: .requiresApproval) == .init(text: "Requires a one-time approval", isError: false))
    }

    @Test func unavailableIsError() {
        #expect(make(status: .unavailable("Missing")) == .init(text: "Missing", isError: true))
    }

    @Test(arguments: [
        (CutoffReason.lowBattery(threshold: 20), "Turned off: battery below 20%"),
        (.thermal, "Turned off: Mac is too hot"),
        (.helperRestarted, "Turned off: helper restarted"),
    ])
    func cutoff(reason: CutoffReason, expected: String) {
        #expect(make(notice: .cutoff(reason)).text == expected)
    }

    @Test(arguments: [
        (CutoffReason.lowBattery(threshold: 20), "Battery is below 20%"),
        (.thermal, "Mac is too hot to stay awake"),
    ])
    func refusal(reason: CutoffReason, expected: String) {
        #expect(make(notice: .refused(reason)).text == expected)
    }

    @Test func errorWinsOverEverything() {
        #expect(make(active: true, notice: .cutoff(.thermal), error: "x") == .init(text: "Couldn't change the sleep setting", isError: true))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: the test command with `-only-testing:WorkdeckTests/ClosedLidModeSubtitleTests`
Expected: build fails with `cannot find type 'ClosedLidModeSubtitle' in scope`.

- [ ] **Step 3: Create `Workdeck/Features/ClosedLidMode/ClosedLidModeSubtitle.swift`**

```swift
import Foundation

/// The secondary line under the Closed-Lid Mode toggle.
struct ClosedLidModeSubtitle: Equatable {
    let text: String
    let isError: Bool

    static func make(
        helperStatus: HelperStatus,
        isActive: Bool,
        power: PowerSnapshot,
        threshold: Int,
        notice: LidSleepController.Notice?,
        lastError: String?
    ) -> ClosedLidModeSubtitle {
        if lastError != nil {
            return ClosedLidModeSubtitle(text: "Couldn't change the sleep setting", isError: true)
        }
        switch helperStatus {
        case .requiresApproval:
            return ClosedLidModeSubtitle(text: "Requires a one-time approval", isError: false)
        case let .unavailable(message):
            return ClosedLidModeSubtitle(text: message, isError: true)
        case .notRegistered, .enabled:
            break
        }
        if isActive {
            if power.isOnBattery, power.batteryPercent != nil {
                return ClosedLidModeSubtitle(
                    text: "Mac won't sleep when the lid is closed · Turns off below \(threshold)% battery",
                    isError: false
                )
            }
            return ClosedLidModeSubtitle(text: "Mac won't sleep when the lid is closed", isError: false)
        }
        switch notice {
        case let .cutoff(reason):
            return ClosedLidModeSubtitle(text: "Turned off: \(cutoffText(reason))", isError: false)
        case let .refused(reason):
            return ClosedLidModeSubtitle(text: refusalText(reason), isError: false)
        case nil:
            return ClosedLidModeSubtitle(text: "Mac sleeps normally when the lid is closed", isError: false)
        }
    }

    private static func cutoffText(_ reason: CutoffReason) -> String {
        switch reason {
        case let .lowBattery(threshold): "battery below \(threshold)%"
        case .thermal: "Mac is too hot"
        case .helperRestarted: "helper restarted"
        }
    }

    private static func refusalText(_ reason: CutoffReason) -> String {
        switch reason {
        case let .lowBattery(threshold): "Battery is below \(threshold)%"
        case .thermal: "Mac is too hot to stay awake"
        case .helperRestarted: "Turned off: helper restarted"
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same as Step 2.
Expected: `** TEST SUCCEEDED **`, no `recorded an issue` lines.

- [ ] **Step 5: Commit**

```bash
git add Workdeck/Features/ClosedLidMode/ClosedLidModeSubtitle.swift WorkdeckTests/ClosedLidModeSubtitleTests.swift
git commit -m "Add Closed-Lid Mode subtitle mapping"
```

---

### Task 11: Popover, Settings window, and app wiring

**Files:**
- Create: `Workdeck/Features/ClosedLidMode/ClosedLidModeRow.swift`
- Create: `Workdeck/App/PopoverView.swift`
- Create: `Workdeck/App/SettingsView.swift`
- Create: `Workdeck/App/AppDelegate.swift`
- Replace: `Workdeck/App/WorkdeckApp.swift`

**Interfaces:**
- Consumes: everything from Tasks 5–10.
- Produces: the running app — menu bar icon reflecting `isActive`, popover with the Closed-Lid Mode row and Quit, Settings window. `AppDelegate` owns `settings: AppSettings` and `lidSleep: LidSleepController`, calls `refresh()` on launch and `prepareForTermination()` on quit.

Wiring that the Review Focus depends on: `PopoverView` calls `controller.refresh()` in `.task` (picks up approval granted in System Settings); `SettingsView` calls `controller.scheduleSafeguardCheck()` in `.onChange(of: settings.batteryThreshold)` (threshold raised above current charge).

- [ ] **Step 1: Create `Workdeck/Features/ClosedLidMode/ClosedLidModeRow.swift`**

```swift
import SwiftUI

struct ClosedLidModeRow: View {
    let controller: LidSleepController

    var body: some View {
        let subtitle = ClosedLidModeSubtitle.make(
            helperStatus: controller.helperStatus,
            isActive: controller.isActive,
            power: controller.power,
            threshold: controller.threshold,
            notice: controller.notice,
            lastError: controller.lastError
        )

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Closed-Lid Mode")
                Text(subtitle.text)
                    .font(.caption)
                    .foregroundStyle(subtitle.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(controller.lastError ?? "")
                if controller.helperStatus == .requiresApproval {
                    Button("Open System Settings…") {
                        controller.openApprovalSettings()
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 8)

            Toggle("Closed-Lid Mode", isOn: Binding(
                get: { controller.isActive },
                set: { enabled in Task { await controller.setEnabled(enabled) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!controller.canToggle)
        }
    }
}
```

- [ ] **Step 2: Create `Workdeck/App/PopoverView.swift`**

```swift
import AppKit
import SwiftUI

struct PopoverView: View {
    let controller: LidSleepController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workdeck")
                    .font(.headline)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .simultaneousGesture(TapGesture().onEnded {
                    // Menu bar apps are not active by default; bring the Settings window to front.
                    NSApp.activate()
                })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ClosedLidModeRow(controller: controller)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit Workdeck")
                    Spacer()
                    Text("⌘Q")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .task {
            await controller.refresh()
        }
    }
}
```

- [ ] **Step 3: Create `Workdeck/App/SettingsView.swift`**

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: LidSleepController

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }

            Section {
                Picker("Turn off below", selection: $settings.batteryThreshold) {
                    ForEach(AppSettings.thresholdOptions, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }
                LabeledContent("Helper") {
                    helperStatus
                }
            } header: {
                Text("Closed-Lid Mode")
            } footer: {
                Text("Also turns off if the Mac gets too hot.")
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: HelperConstants.version(of: .main))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onChange(of: settings.batteryThreshold) {
            controller.scheduleSafeguardCheck()
        }
        .task {
            await controller.refresh()
        }
    }

    @ViewBuilder
    private var helperStatus: some View {
        switch controller.helperStatus {
        case .enabled:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notRegistered:
            Text("Installed on first use")
                .foregroundStyle(.secondary)
        case .requiresApproval:
            Button("Open System Settings…") {
                controller.openApprovalSettings()
            }
        case let .unavailable(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
```

- [ ] **Step 4: Create `Workdeck/App/AppDelegate.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) lazy var lidSleep = LidSleepController(
        helper: HelperClient(),
        installer: HelperInstaller(),
        powerMonitor: PowerSourceMonitor(),
        thermalMonitor: ThermalMonitor(),
        settings: settings,
        appVersion: HelperConstants.version(of: .main)
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await lidSleep.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lidSleep.prepareForTermination()
    }
}
```

- [ ] **Step 5: Replace `Workdeck/App/WorkdeckApp.swift`**

```swift
import SwiftUI

@main
struct WorkdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(controller: appDelegate.lidSleep)
        } label: {
            Image(systemName: appDelegate.lidSleep.isActive ? "rectangle.stack.fill" : "rectangle.stack")
                .accessibilityLabel("Workdeck")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings, controller: appDelegate.lidSleep)
        }
    }
}
```

- [ ] **Step 6: Run the full suite**

Run: the test command.
Expected: `** TEST SUCCEEDED **` and `Test run with 50 tests in 8 suites passed`.

- [ ] **Step 7: Launch the app and check it stays up**

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' -derivedDataPath build/dd build 2>&1 | grep -E "error:|warning:|\*\* BUILD" | grep -v appintents
build/dd/Build/Products/Debug/Workdeck.app/Contents/MacOS/Workdeck > build/run.log 2>&1 &
APP_PID=$!
sleep 3
ps -p $APP_PID -o pid,stat,comm
kill $APP_PID
cat build/run.log
rm -rf build
```

Expected: `** BUILD SUCCEEDED **`, no warnings; `ps` shows the process still running after 3 s; `run.log` contains no crash or `dispatch_assert_queue` output. (If `sleep` is blocked in your harness, wait ~3 s by other means.)

- [ ] **Step 8: Commit**

```bash
git add Workdeck
git commit -m "Add menu bar popover, Settings window, and app wiring"
```

---

### Task 12: Final documentation and manual verification

**Files:**
- Create: `docs/testing.md`
- Replace: `README.md`
- Modify: `CLAUDE.md` (append Verification section)

**Interfaces:**
- Consumes: the finished app.
- Produces: final docs; a completed manual checklist run by the user.

- [ ] **Step 1: Create `docs/testing.md`**

````markdown
# Manual Testing

Root-level behavior cannot be covered by unit tests. Run this checklist after changing the helper, `HelperClient`, or `LidSleepController`.

Check the system setting at any point with:

```bash
pmset -g | grep SleepDisabled
```

`SleepDisabled 1` means sleep is disabled; no output (or `0`) means normal sleep.

## Setup

1. Build and run the `Workdeck` scheme from Xcode.
2. Make sure `pmset -g | grep SleepDisabled` prints nothing.

## Checklist

| # | Scenario | Steps | Expected |
|---|---|---|---|
| 1 | First-run approval | Open the popover, turn on Closed-Lid Mode. | Subtitle reads "Requires a one-time approval"; toggle is disabled; "Open System Settings…" opens Login Items & Extensions. |
| 2 | Approval picked up | Allow Workdeck in System Settings, reopen the popover. | Toggle is enabled; turning it on succeeds; menu bar icon becomes filled; `SleepDisabled 1`. |
| 3 | Lid closed on adapter | With the mode on, start `ping 1.1.1.1` in Terminal (or an SSH session from another machine), close the lid for 2 minutes, open it. | The ping (or SSH session) kept running without a gap. |
| 4 | Lid closed on battery | Unplug, repeat scenario 3. | Same as 3; subtitle mentions "Turns off below 20% battery". |
| 5 | Turn off | Turn the toggle off. | Icon becomes outline; `SleepDisabled` gone. |
| 6 | Quit restores sleep | Turn on, choose Quit Workdeck. | `SleepDisabled` gone. |
| 7 | Crash restores sleep | Turn on, then `pkill -9 -x Workdeck`. | `SleepDisabled` gone within a few seconds. |
| 8 | Reboot restores sleep | Turn on, restart the Mac without quitting Workdeck first. | After login, `SleepDisabled` gone. |
| 9 | Battery cutoff | On battery, set "Turn off below" just above the current charge in Settings while the mode is on. | Mode turns off; subtitle "Turned off: battery below N%". |
| 10 | Battery refusal | With charge below the threshold on battery, try to turn the mode on. | Toggle stays off; subtitle "Battery is below N%". |
| 11 | Helper restart | Turn on, then `sudo launchctl kickstart -k system/com.appcreators.workdeck.helper`, reopen the popover. | Mode is off; subtitle "Turned off: helper restarted"; `SleepDisabled` gone. |
| 12 | Launch at login | Enable "Launch at login" in Settings, log out and back in. | Workdeck icon appears in the menu bar. |

Thermal cutoff is covered by unit tests only; it cannot be triggered reliably by hand.
````

- [ ] **Step 2: Replace `README.md`**

````markdown
# Workdeck

A minimal macOS menu bar toolbox for developers.

## Features

### Closed-Lid Mode

Keeps your Mac awake while the lid is closed — for long builds, remote sessions over SSH, or carrying a working Mac in a bag.

- Toggle it from the Workdeck popover in the menu bar. The menu bar icon fills in while it is on.
- **Safeguards:** turns itself off when running on battery below a configurable threshold (20 % by default) and when the Mac gets too hot.
- **Sleep always comes back:** normal sleep is restored when Workdeck quits, crashes, or the Mac restarts.

> **Note:** While Closed-Lid Mode is on, macOS does not sleep at all — idle sleep and Apple menu → Sleep are disabled too. The display still turns off as usual.

## Requirements

- macOS 26 or later
- Xcode 27 to build

## Building

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' build
xcodebuild -scheme Workdeck -destination 'platform=macOS' test
```

Or open `Workdeck.xcodeproj` and run the `Workdeck` scheme. Both the `Workdeck` and `WorkdeckHelper` targets are signed with team `U7HS7ZJUWC`; if you build with a different team, also update `teamIdentifier` in `Shared/HelperConstants.swift`.

Workdeck is not sandboxed and is not distributed through the Mac App Store.

## First Run

The first time you turn on Closed-Lid Mode, Workdeck registers its helper and macOS asks for approval:

1. Click **Open System Settings…** in the popover.
2. In **General → Login Items & Extensions**, allow Workdeck.
3. Reopen the popover and turn on Closed-Lid Mode.

## Settings

Open Settings from the gear button in the popover.

- **Launch at login**
- **Turn off below** — battery threshold, 10–50 %

## How It Works

Keeping a Mac awake with the lid closed requires the root-only `SleepDisabled` power setting (`pmset -a disablesleep 1`); the public power-assertion APIs used by `caffeinate` do not prevent clamshell sleep.

- **Workdeck** is the menu bar app. It owns all decisions: when to turn the mode on or off and which safeguards apply.
- **WorkdeckHelper** is a small launchd daemon registered with `SMAppService` that runs as root. It can only set `disablesleep` to 0 or 1 and report the current value. It accepts XPC connections only from Workdeck signed by the same team.

Sleep is restored in every exit path:

1. **Quit** — Workdeck turns the mode off before exiting.
2. **Crash or force quit** — the helper notices the dropped XPC connection and turns the mode off.
3. **Restart** — the helper starts at boot and resets the setting.
4. **Helper crash** — the relaunched helper resets the setting and Workdeck shows "Turned off: helper restarted".

## Uninstalling

1. Turn off Closed-Lid Mode and quit Workdeck.
2. In **System Settings → General → Login Items & Extensions**, turn off Workdeck.
3. Delete `Workdeck.app`.

If sleep ever stays disabled, reset it manually:

```bash
sudo pmset -a disablesleep 0
```

## Troubleshooting

- **Check the current state:** `pmset -g | grep SleepDisabled` — no output means sleep works normally.
- **"Couldn't change the sleep setting" after rebuilding in Xcode:** launchd may still be running an older helper build. Turn Workdeck off and on again in Login Items & Extensions. As a last resort, `sudo sfltool resetbtm` resets all background item approvals (for every app) and requires a restart.

## Project Structure

```
Workdeck/          Menu bar app (SwiftUI)
  App/             Scenes and top-level views
  Core/            Helper client and installer, settings
  Features/        One folder per tool
WorkdeckHelper/    Privileged launchd helper
Shared/            Code compiled into both the app and the helper
LaunchDaemons/     launchd job definition embedded in the app bundle
WorkdeckTests/     Unit tests (Swift Testing)
specs/             Design specs
plans/             Implementation plans
docs/              Other documentation, including the manual testing checklist
```
````

- [ ] **Step 3: Append to `CLAUDE.md`**

```markdown

## Verification

- Root-level behavior (helper approval, lid close, crash and reboot recovery) cannot be unit tested; follow `docs/testing.md` after changing the helper, `HelperClient`, or `LidSleepController`.
```

- [ ] **Step 4: Run the full suite one last time**

Run: the test command.
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add docs/testing.md README.md CLAUDE.md
git commit -m "Add manual testing checklist and complete README"
```

- [ ] **Step 6: Hand the manual checklist to the user**

The checklist needs System Settings approval, closing the lid, and a reboot, which an agent cannot do. Ask the user to run the app from Xcode and walk through `docs/testing.md`, then record which items passed. Fix any failure through superpowers:systematic-debugging before declaring the feature done.
