import CoreGraphics
import Foundation
import Testing
@testable import SwiftExileCore

@Suite struct GeometryTests {
    @Test func wineBorderlessFullscreenUsesWholeFrame() {
        // Observed on the dev Mac: PoE2 under NotProton, untitled, 2560×1440 at (0,0).
        let geometry = GameWindowGeometry(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isTitled: false, isNativeFullScreen: false)
        #expect(geometry.contentRect(titleBarHeight: 28) == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    }

    @Test func titledWindowLosesTitleBar() {
        let geometry = GameWindowGeometry(frame: CGRect(x: 100, y: 50, width: 1280, height: 748), isTitled: true, isNativeFullScreen: false)
        #expect(geometry.contentRect(titleBarHeight: 28) == CGRect(x: 100, y: 78, width: 1280, height: 720))
    }

    @Test func nativeFullscreenKeepsWholeFrame() {
        let geometry = GameWindowGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), isTitled: true, isNativeFullScreen: true)
        #expect(geometry.contentRect(titleBarHeight: 28).height == 1117)
    }

    @Test func quartzToCocoaOnPrimary() {
        // Primary 2560×1440: a window at the top-left in Quartz sits at y = 1440 - h in Cocoa.
        let cocoa = ScreenCoordinates.cocoaRect(fromQuartz: CGRect(x: 0, y: 0, width: 800, height: 600), primaryHeight: 1440)
        #expect(cocoa == CGRect(x: 0, y: 840, width: 800, height: 600))
    }

    @Test func quartzToCocoaOnSecondaryAboveBaseline() {
        // Secondary display from the dev Mac: Cocoa frame (2560, -388, 1728×1117).
        // Its Quartz origin is y = 1440 - (-388 + 1117) = 711.
        let quartz = CGRect(x: 2560, y: 711, width: 1728, height: 1117)
        let cocoa = ScreenCoordinates.cocoaRect(fromQuartz: quartz, primaryHeight: 1440)
        #expect(cocoa == CGRect(x: 2560, y: -388, width: 1728, height: 1117))
    }
}

@Suite struct ProcessArgumentsTests {
    private func buffer(argc: Int32, exec: String, args: [String], env: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(exec.utf8) + [0, 0, 0, 0] // exec path + padding
        for arg in args { bytes += Array(arg.utf8) + [0] }
        for entry in env { bytes += Array(entry.utf8) + [0] }
        bytes += [0]
        return bytes
    }

    @Test func parsesArgumentsIncludingEmptyOnes() throws {
        // Shape observed for PathOfExileSteam.exe: argv contains an empty string.
        let bytes = buffer(
            argc: 3,
            exec: "/var/folders/x/winetemp/PathOfExileSteam.exe",
            args: [#"S:\steamapps\common\Path of Exile 2\PathOfExileSteam.exe"#, "--nopatch", ""],
            env: ["WINEPREFIX=/pfx", "STEAM_COMPAT_INSTALL_PATH=/install", "PWD=/install"]
        )
        let parsed = try #require(ProcessArguments.parse(bytes))
        #expect(parsed.arguments.count == 3)
        #expect(parsed.arguments[1] == "--nopatch")
        #expect(parsed.environment["WINEPREFIX"] == "/pfx")
        #expect(parsed.environment["STEAM_COMPAT_INSTALL_PATH"] == "/install")
    }

    @Test func skipsWinePaddingBeforeEnvironment() throws {
        // Real layout of PathOfExileSteam.exe under NotProton: empty strings after argv.
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/tmp/winetemp/PathOfExileSteam.exe".utf8) + [0, 0, 0, 0, 0]
        bytes += Array(#"S:\steamapps\common\Path of Exile 2\PathOfExileSteam.exe"#.utf8) + [0]
        bytes += Array("--nopatch".utf8) + [0, 0, 0, 0, 0, 0, 0, 0]
        bytes += Array("WINEPREFIX=/pfx".utf8) + [0] + Array("PWD=/install".utf8) + [0]
        let parsed = try #require(ProcessArguments.parse(bytes))
        #expect(parsed.environment["WINEPREFIX"] == "/pfx")
        #expect(parsed.environment["PWD"] == "/install")
    }

    @Test func detectsWineFlavor() {
        let args = ProcessArguments(executablePath: "/x", arguments: ["S:\\game.exe"],
                                    environment: ["WINEPREFIX": "/pfx", "STEAM_COMPAT_INSTALL_PATH": "/install"])
        let flavor = GameFlavor.detect(bundleID: nil, processArguments: args)
        #expect(flavor == .wine(prefix: "/pfx", installDir: "/install"))
        #expect(flavor.derivedClientLogPath == "/install/logs/Client.txt")
    }

    @Test func detectsNativeFlavor() {
        let args = ProcessArguments(executablePath: "/Applications/PoE2.app/Contents/MacOS/PoE2", arguments: [], environment: [:])
        #expect(GameFlavor.detect(bundleID: "com.GGG.PathOfExile2", processArguments: args) == .native(bundleID: "com.GGG.PathOfExile2"))
    }

    @Test func readsOwnProcess() throws {
        let own = try #require(ProcessArguments.read(pid: ProcessInfo.processInfo.processIdentifier))
        #expect(!own.executablePath.isEmpty)
        #expect(own.environment["PATH"] != nil || !own.environment.isEmpty)
    }
}

@Suite struct OverlayFocusModelTests {
    typealias Effect = OverlayFocusModel.Effect

    private func attachedAndFocused() -> OverlayFocusModel {
        var model = OverlayFocusModel()
        _ = model.attached()
        _ = model.focusChanged(gameFrontmost: true, overlayIsKey: false)
        return model
    }

    @Test func attachBroadcastsAndShowsOnFocus() {
        var model = OverlayFocusModel()
        #expect(model.attached() == [.broadcastOverlayAttached])
        let effects = model.focusChanged(gameFrontmost: true, overlayIsKey: false)
        #expect(effects == [.broadcastFocusChange(game: true, overlay: false, usingHotkey: false), .show])
        #expect(model.isVisible)
    }

    @Test func toggleMakesOverlayInteractableWithHotkeyFlag() {
        var model = attachedAndFocused()
        let effects = model.toggle()
        #expect(effects.contains(.setInteractable(true)))
        #expect(effects.contains(.broadcastFocusChange(game: false, overlay: true, usingHotkey: true)))
        #expect(model.isInteractable)
        #expect(!model.gameActive)
    }

    @Test func panelBecomingKeyDoesNotRebroadcast() {
        var model = attachedAndFocused()
        _ = model.toggle()
        #expect(model.focusChanged(gameFrontmost: true, overlayIsKey: true) == [])
    }

    @Test func toggleBackFocusesGame() {
        var model = attachedAndFocused()
        _ = model.toggle()
        _ = model.focusChanged(gameFrontmost: true, overlayIsKey: true)
        let effects = model.toggle()
        #expect(effects.prefix(2) == [.setInteractable(false), .focusGame])
        #expect(effects.contains(.broadcastFocusChange(game: true, overlay: false, usingHotkey: true)))
        #expect(model.gameActive)
    }

    @Test func gameGrabbingFocusWhileInteractableIsRetaken() {
        // Windowed fullscreen under Wine: the game takes key focus about once a second.
        var model = attachedAndFocused()
        _ = model.toggle()
        _ = model.focusChanged(gameFrontmost: true, overlayIsKey: true)
        for _ in 0..<5 {
            #expect(model.focusChanged(gameFrontmost: true, overlayIsKey: false) == [.retakeFocus])
            #expect(model.isInteractable)
            #expect(!model.gameActive)
            #expect(model.focusChanged(gameFrontmost: true, overlayIsKey: true) == [])
        }
    }

    @Test func retakeEvenIfPanelNeverBecameKey() {
        var model = attachedAndFocused()
        _ = model.toggle()
        #expect(model.focusChanged(gameFrontmost: true, overlayIsKey: false) == [.retakeFocus])
        #expect(model.isInteractable)
    }

    @Test func switchingToAnotherAppHidesOverlay() {
        var model = attachedAndFocused()
        let effects = model.focusChanged(gameFrontmost: false, overlayIsKey: false)
        #expect(effects == [.broadcastFocusChange(game: false, overlay: false, usingHotkey: false), .hide])
    }

    @Test func returningToGameWhileInteractableDropsInteractable() {
        // OverlayWindow.ts:193-195: isActive && isInteractable → isInteractable = false.
        var model = attachedAndFocused()
        _ = model.toggle()
        _ = model.focusChanged(gameFrontmost: false, overlayIsKey: false) // user went to another app
        let effects = model.focusChanged(gameFrontmost: true, overlayIsKey: false)
        #expect(effects.contains(.setInteractable(false)))
        #expect(effects.contains(.broadcastFocusChange(game: true, overlay: false, usingHotkey: false)))
        #expect(!model.isInteractable)
    }

    @Test func hideOnBlurFollowsRenderState() {
        var model = attachedAndFocused()
        #expect(model.setHideOverlayOnBlur(true) == [])
        #expect(model.renderState(shouldShow: false) == [.hide])
        #expect(model.renderState(shouldShow: true) == [.show])
    }

    @Test func detachHides() {
        var model = attachedAndFocused()
        let effects = model.detached()
        #expect(effects.contains(.hide))
        #expect(!model.isAttached)
    }

    @Test func focusGameWithoutInteractableDoesNothing() {
        var model = attachedAndFocused()
        #expect(model.assertGameActive() == [])
    }
}

@Suite struct KeyNamesTests {
    @Test func overlayKeyFromKeyPress() {
        #expect(KeyNames.hotkeyString(macKeyCode: 49, ctrl: false, shift: true, alt: false) == "Shift + Space")
        #expect(KeyNames.hotkeyString(macKeyCode: 53, ctrl: false, shift: false, alt: false) == "Escape")
        #expect(KeyNames.hotkeyString(macKeyCode: 13, ctrl: true, shift: false, alt: false) == "Ctrl + W")
        #expect(KeyNames.hotkeyString(macKeyCode: 122, ctrl: false, shift: false, alt: true) == "Alt + F1")
    }

    @Test func modifierOrderMatchesUpstream() {
        #expect(KeyNames.hotkeyString(keys: ["D"], ctrl: true, shift: true, alt: true) == "Ctrl + Shift + Alt + D")
        #expect(KeyNames.hotkeyString(keys: ["Alt", "Ctrl", "C"]) == "Ctrl + Alt + C")
        #expect(KeyNames.hotkeyString(keys: ["Alt"]) == "Alt")
    }

    @Test func unknownKeyCodeIsNil() {
        #expect(KeyNames.hotkeyString(macKeyCode: 255, ctrl: false, shift: false, alt: false) == nil)
    }

    @Test func allLettersAndDigitsMapped() {
        let names = Set(KeyNames.byMacKeyCode.values)
        for scalar in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            #expect(names.contains(String(scalar)))
        }
        #expect(names.contains("F12"))
    }
}

@Suite struct HostConfigTests {
    @Test func decodesRendererPayload() throws {
        let json = #"{"shortcuts":[],"restoreClipboard":true,"clientLog":null,"gameConfig":null,"stashScroll":true,"overlayKey":"Alt + Space","logKeys":false,"windowTitle":"Path of Exile 2","language":"en","readClientLog":false,"libraryAlpha":false,"libraryOutputPath":null,"initialDelay":48,"hideOverlayOnBlur":true}"#
        let config = try JSONValue(encoding: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))).decode(HostConfig.self)
        #expect(config.overlayKey == "Alt + Space")
        #expect(config.hideOverlayOnBlur)
        #expect(config.clientLog == nil)
    }

    @Test func missingFieldsUseDefaults() throws {
        let config = try JSONDecoder().decode(HostConfig.self, from: Data("{}".utf8))
        #expect(config == HostConfig.default)
    }
}
