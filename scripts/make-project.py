#!/usr/bin/env python3
"""Writes Aerilo.xcodeproj/project.pbxproj. Run from the repository root after adding a target or a
build setting; source files need no entry, because every target follows its folders.

  Aerilo         Mac App Store edition (sandboxed)          Shared/ + Aerilo/
  AeriloDirect   Mac download edition (DMG, not sandboxed)  Shared/ + Aerilo/
  AeriloMobile   iPhone, iPad, Apple TV and Vision Pro      Shared/ + AeriloMobile/
  AeriloUITests  drives AeriloMobile in the simulator       AeriloUITests/
"""
TEAM = "TM3Y76QWZV"
VERSION, BUILD = "1.0.1", "2"
PHOTOS = "Aerilo compares your photos on this device to find duplicates, similar shots, old screenshots and large videos. Nothing is deleted until you choose."
A = "A100000000000000000000"


def settings(d):
    return "".join(f"\n\t\t\t\t{k} = {v};" for k, v in d.items())


def config(cid, name, d):
    return f"\n\t\t{cid} /* {name} */ = {{isa = XCBuildConfiguration; buildSettings = {{{settings(d)}\n\t\t\t}}; name = {name}; }};"


def target(tid, name, cfglist, phases, product, groups, kind="application", deps=""):
    return f"""
\t\t{tid} /* {name} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cfglist};
\t\t\tbuildPhases = ({", ".join(phases)}, );
\t\t\tbuildRules = ();
\t\t\tdependencies = ({deps});
\t\t\tfileSystemSynchronizedGroups = ({", ".join(groups)}, );
\t\t\tname = {name};
\t\t\tproductName = {name};
\t\t\tproductReference = {product};
\t\t\tproductType = "com.apple.product-type.{kind}";
\t\t}};"""


common = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": TEAM,
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "Aerilo",
    "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
    "INFOPLIST_KEY_LSApplicationCategoryType": '"public.app-category.utilities"',
    "INFOPLIST_KEY_NSHumanReadableCopyright": '"© 2026 Aerilo"',
    "INFOPLIST_KEY_NSPhotoLibraryUsageDescription": f'"{PHOTOS}"',
    "MARKETING_VERSION": VERSION,
    "PRODUCT_NAME": "Aerilo",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "SWIFT_VERSION": "5.0",
}


def mac(bundle, entitlements, direct):
    d = dict(common)
    d.update({
        "CODE_SIGN_ENTITLEMENTS": f"Config/{entitlements}",
        "COMBINE_HIDPI_IMAGES": "YES",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/../Frameworks", )',
        "PRODUCT_BUNDLE_IDENTIFIER": bundle,
        "SDKROOT": "macosx",
    })
    if direct:
        d["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = '"$(inherited) AERILO_DIRECT"'
    return d


mobile = dict(common)
mobile.update({
    # The same identifier as the Mac App Store edition: one listing, every platform.
    "PRODUCT_BUNDLE_IDENTIFIER": "app.aerilo.Aerilo",
    "SDKROOT": "auto",
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator appletvos appletvsimulator xros xrsimulator"',
    "TARGETED_DEVICE_FAMILY": '"1,2,3,7"',
    "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
    "TVOS_DEPLOYMENT_TARGET": "26.0",
    "XROS_DEPLOYMENT_TARGET": "26.0",
    "SUPPORTS_MACCATALYST": "NO",
    "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations": '"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": '"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
    "LD_RUNPATH_SEARCH_PATHS": '("$(inherited)", "@executable_path/Frameworks", )',
    '"ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletv*]"': '"App Icon & Top Shelf Image"',
    '"ASSETCATALOG_COMPILER_APPICON_NAME[sdk=xr*]"': "AppIconVision",
})

uitests = {
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": TEAM,
    "GENERATE_INFOPLIST_FILE": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
    "MARKETING_VERSION": VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": "app.aerilo.Aerilo.uitests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SDKROOT": "auto",
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator appletvos appletvsimulator"',
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"1,2,3"',
    "TVOS_DEPLOYMENT_TARGET": "26.0",
    "TEST_TARGET_NAME": "AeriloMobile",
}

project_debug = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "26.0", "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": '"DEBUG $(inherited)"', "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
}
project_release = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "26.0", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES",
}

phase = lambda i, kind: f"\n\t\t{A}{i} = {{isa = {kind}; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};"
SHARED, MACDIR, MOBDIR = f"{A}11 /* Shared */", f"{A}10 /* Aerilo */", f"{A}12 /* AeriloMobile */"

out = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{}};
\tobjectVersion = 77;
\tobjects = {{
\t\t{A}01 = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; name = "Aerilo.app"; path = Aerilo.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{A}02 = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; name = "AeriloDirect.app"; path = Aerilo.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{A}05 = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; name = "AeriloMobile.app"; path = Aerilo.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{A}10 /* Aerilo */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = Aerilo; sourceTree = "<group>"; }};
\t\t{A}11 /* Shared */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = Shared; sourceTree = "<group>"; }};
\t\t{A}12 /* AeriloMobile */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = AeriloMobile; sourceTree = "<group>"; }};
\t\t{A}13 /* AeriloUITests */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = AeriloUITests; sourceTree = "<group>"; }};
\t\t{A}06 = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = AeriloUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{A}90 = {{isa = PBXContainerItemProxy; containerPortal = {A}00 /* Project object */; proxyType = 1; remoteGlobalIDString = {A}42; remoteInfo = AeriloMobile; }};
\t\t{A}91 = {{isa = PBXTargetDependency; target = {A}42 /* AeriloMobile */; targetProxy = {A}90; }};
\t\t{A}03 = {{isa = PBXGroup; children = ({A}11, {A}10, {A}12, {A}13, {A}04, ); sourceTree = "<group>"; }};
\t\t{A}04 /* Products */ = {{isa = PBXGroup; children = ({A}01, {A}02, {A}05, {A}06, ); name = Products; sourceTree = "<group>"; }};"""
for base in ("2", "3", "7", "8"):
    out += phase(base + "1", "PBXSourcesBuildPhase") + phase(base + "2", "PBXFrameworksBuildPhase") + phase(base + "3", "PBXResourcesBuildPhase")
out += target(f"{A}40", "Aerilo", f"{A}50", [f"{A}21", f"{A}22", f"{A}23"], f"{A}01", [SHARED, MACDIR])
out += target(f"{A}41", "AeriloDirect", f"{A}51", [f"{A}31", f"{A}32", f"{A}33"], f"{A}02", [SHARED, MACDIR])
out += target(f"{A}42", "AeriloMobile", f"{A}53", [f"{A}71", f"{A}72", f"{A}73"], f"{A}05", [SHARED, MOBDIR])
out += target(f"{A}43", "AeriloUITests", f"{A}54", [f"{A}81", f"{A}82", f"{A}83"], f"{A}06", [f"{A}13 /* AeriloUITests */"], kind="bundle.ui-testing", deps=f"{A}91, ")
out += f"""
\t\t{A}00 /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{ BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2710; LastUpgradeCheck = 2710; TargetAttributes = {{ {A}43 = {{ TestTargetID = {A}42; }}; }}; }};
\t\t\tbuildConfigurationList = {A}52;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (en, Base, );
\t\t\tmainGroup = {A}03;
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {A}04 /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = ({A}40, {A}41, {A}42, {A}43, );
\t\t}};"""
out += config(f"{A}60", "Debug", project_debug) + config(f"{A}61", "Release", project_release)
store, direct = mac("app.aerilo.Aerilo", "AppStore.entitlements", False), mac("app.aerilo.Aerilo.direct", "Direct.entitlements", True)
out += config(f"{A}62", "Debug", store) + config(f"{A}63", "Release", store)
out += config(f"{A}64", "Debug", direct) + config(f"{A}65", "Release", direct)
out += config(f"{A}66", "Debug", mobile) + config(f"{A}67", "Release", mobile)
out += config(f"{A}68", "Debug", uitests) + config(f"{A}69", "Release", uitests)
for lid, a, b in ((52, 60, 61), (50, 62, 63), (51, 64, 65), (53, 66, 67), (54, 68, 69)):
    out += f"\n\t\t{A}{lid} = {{isa = XCConfigurationList; buildConfigurations = ({A}{a}, {A}{b}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};"
out += f"\n\t}};\n\trootObject = {A}00 /* Project object */;\n}}\n"
open("Aerilo.xcodeproj/project.pbxproj", "w").write(out)
print("wrote Aerilo.xcodeproj/project.pbxproj")
