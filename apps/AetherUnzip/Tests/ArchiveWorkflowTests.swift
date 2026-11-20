import XCTest
#if os(macOS)
import AppKit

@MainActor
final class ArchiveWorkflowTests: XCTestCase {
    func testOpenAndExtractWithFormatProfile() throws {
        let bundle = Bundle(for: Self.self)
        let profile = try XCTUnwrap(bundle.url(forResource: "format-profile", withExtension: "json"))
        let wrapped = try XCTUnwrap(bundle.url(forResource: "profile-box", withExtension: "bin"))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let definition = folder.appending(path: "Wrapper.json")
        let source = folder.appending(path: "ProfileWorkflow.bin")
        let destination = folder.appending(path: "Output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: profile, to: definition)
        try FileManager.default.copyItem(at: wrapped, to: source)

        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["open-archive"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("o", modifierFlags: [.command, .shift])
        try pick(definition, in: app)
        let choose = app.buttons["choose-profile-archive"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10), app.debugDescription)
        choose.click()
        try pick(source, in: app)
        XCTAssertTrue(app.staticTexts["ProfileWorkflow.bin"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["extract-all"].click()
        try pickExtractionFolder(destination, in: app)
        XCTAssertTrue(app.staticTexts["Extraction completed in ProfileWorkflow."].waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "ProfileWorkflow/notes.txt"), encoding: .utf8),
                       "AetherUnzip fixture\n")
    }

    func testOpenNestedArchiveExtractAndReturn() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "nested", withExtension: "zip"))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = folder.appending(path: "NestedWorkflow.zip")
        let destination = folder.appending(path: "Output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: fixture, to: source)

        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "0"]
        app.launch()
        let open = app.buttons["open-archive"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        try pick(source, in: app)

        XCTAssertTrue(app.staticTexts["NestedWorkflow.zip"].waitForExistence(timeout: 12))
        let firstChild = app.buttons["open-nested-2"].firstMatch
        XCTAssertTrue(firstChild.waitForExistence(timeout: 8))
        firstChild.click()
        let secondChild = app.buttons["open-nested-0"].firstMatch
        XCTAssertTrue(secondChild.waitForExistence(timeout: 8))
        secondChild.click()
        XCTAssertTrue(app.staticTexts["deep.zip"].waitForExistence(timeout: 8))

        let extract = app.buttons["extract-all"]
        XCTAssertTrue(extract.isEnabled)
        extract.click()
        try pickExtractionFolder(destination, in: app)
        XCTAssertTrue(app.staticTexts["Extraction completed in deep."].waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "deep/notes.txt"), encoding: .utf8),
                       "AetherUnzip fixture\n")
        let parent = app.buttons["parent-archive"].firstMatch
        parent.click()
        XCTAssertTrue(app.staticTexts["visible.zip"].waitForExistence(timeout: 8))
        parent.click()
        XCTAssertTrue(app.staticTexts["NestedWorkflow.zip"].waitForExistence(timeout: 8))
    }

    func testImportPreviewAndExtractThroughNativePickers() throws {
        try checkArchiveExtraction(extension: "zip", displayedFormat: "ZIP")
    }

    func testFileWorkspaceAddsAFolderThroughTheNativePicker() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Files-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "zip"))
        try FileManager.default.copyItem(at: fixture, to: folder.appending(path: "BrowserArchive.zip"))

        let app = XCUIApplication()
        app.launch()
        let add = app.descendants(matching: .any)["sidebar-add-folder-location"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.click()
        try pick(folder, in: app)
        let archive = app.descendants(matching: .any)["workspace-file-BrowserArchive.zip"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10), app.debugDescription)
        archive.click()
        XCTAssertTrue(app.buttons["extract-all"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testImportAndExtractXP3ThroughNativePickers() throws {
        try checkArchiveExtraction(extension: "xp3", displayedFormat: "XP3")
    }

    func testImportAndExtractWrappedXP3ThroughNativePickers() throws {
        try checkArchiveExtraction(fixture: "xp3-wrapped", extension: "bin", displayedFormat: "XP3")
    }

    private func checkArchiveExtraction(fixture name: String = "sample", extension suffix: String,
                                        displayedFormat: String) throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: suffix))
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = folder.appending(path: "ArchiveWorkflow.\(suffix)")
        let destination = folder.appending(path: "Output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: fixture, to: source)

        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "0"]
        app.launch()
        let open = app.buttons["open-archive"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        try pick(source, in: app)

        XCTAssertTrue(app.staticTexts[source.lastPathComponent].waitForExistence(timeout: 12))
        let formatPrefix = displayedFormat + " ·"
        let format = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
                                                           formatPrefix, formatPrefix)).firstMatch
        XCTAssertTrue(format.exists)
        XCTAssertTrue(app.descendants(matching: .any)["archive-entry-0"].exists)
        let extract = app.buttons["extract-all"]
        XCTAssertTrue(extract.isEnabled)
        extract.click()
        try pickExtractionFolder(destination, in: app)

        XCTAssertTrue(app.staticTexts["Extraction completed in ArchiveWorkflow."].waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "ArchiveWorkflow/notes.txt"), encoding: .utf8),
                       "AetherUnzip fixture\n")
    }

    private func pickExtractionFolder(_ destination: URL, in app: XCUIApplication) throws {
        let choose = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "extraction-choose-folder", "Choose Folder…")).firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        choose.click()
        try pick(destination, in: app)
        app.buttons["confirm-extraction-plan"].firstMatch.click()
    }

    private func pick(_ url: URL, in app: XCUIApplication) throws {
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 8))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = app.textFields["PathTextField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let pasteboard = NSPasteboard.general
        let savedItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(url.path, forType: .string))
        let testContents = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == testContents {
                pasteboard.clearContents()
                if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            }
        }
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, url.path)
        field.typeKey(.return, modifierFlags: [])
        let accept = app.descendants(matching: .any).matching(identifier: "OKButton").firstMatch
        if accept.waitForExistence(timeout: 3) {
            accept.click()
        } else if panel.exists {
            app.typeKey(.return, modifierFlags: [])
        }
    }
}
#else

@MainActor
final class ArchiveWorkflowTests: XCTestCase {
    func testSettingsEditsAndRestoresSafetyLimits() {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app, title: "Settings")

        let conflict = app.buttons["settings-conflict"].firstMatch
        XCTAssertTrue(conflict.waitForExistence(timeout: 8), app.debugDescription)
        let originalConflict = conflict.value as? String ?? "Stop on conflict"
        let newConflict = originalConflict == "Keep existing" ? "Stop on conflict" : "Keep existing"
        conflict.tap()
        XCTAssertTrue(app.buttons[newConflict].firstMatch.waitForExistence(timeout: 8))
        capture("Conflict Preferences", in: app)
        app.buttons[newConflict].firstMatch.tap()
        XCTAssertEqual(conflict.value as? String, newConflict)

        let safety = app.buttons["settings-safety"].firstMatch
        let originalPreset = safety.value as? String ?? "Default"
        safety.tap()
        let field = app.textFields["settings-limit-file"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let originalLimit = field.value as? String ?? "4"
        let save = app.buttons["settings-safety-save"].firstMatch
        replaceLimit(field, in: app, with: "65")
        XCTAssertTrue(app.staticTexts["settings-limit-error-file"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(save.isEnabled)
        capture("Safety Validation", in: app)
        replaceLimit(field, in: app, with: originalLimit == "12" ? "8" : "12")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(safety.waitForExistence(timeout: 8))
        XCTAssertEqual(safety.value as? String, "Custom")

        app.terminate()
        app.launch()
        openSettings(in: app, title: "Settings")
        XCTAssertEqual(conflict.value as? String, newConflict)
        XCTAssertEqual(safety.value as? String, "Custom")
        safety.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let savedLimit = field.value as? String
        XCTAssertEqual(savedLimit, originalLimit == "12" ? "8" : "12")
        app.buttons["settings-safety-reset"].firstMatch.tap()
        XCTAssertEqual(field.value as? String, "4")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(safety.waitForExistence(timeout: 8))
        safety.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        XCTAssertEqual(field.value as? String, savedLimit)
        replaceLimit(field, in: app, with: originalLimit)
        save.tap()
        XCTAssertTrue(safety.waitForExistence(timeout: 8))
        XCTAssertEqual(safety.value as? String, originalPreset)
        conflict.tap()
        app.buttons[originalConflict].firstMatch.tap()
    }

    func testCacheSettingsClearsUnusedPreviewsAndAdjustsLimits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-automaticallyClearPreviewCache", "NO"]
        app.launch()
        openSettings(in: app, title: "Settings")
        let cache = app.buttons["settings-cache"].firstMatch
        XCTAssertTrue(cache.waitForExistence(timeout: 8), app.debugDescription)
        cache.tap()

        let automatic = app.switches["cache-automatic"].firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(automatic.value as? String, "0")
        let clear = app.buttons["cache-clear"].firstMatch
        let reclaimable = app.descendants(matching: .any)["cache-reclaimable"].firstMatch
        XCTAssertTrue(reclaimable.waitForExistence(timeout: 8), app.debugDescription)
        try XCTSkipUnless(clear.exists, "Seed the abandoned preview fixture before running this test on its own.")
        XCTAssertTrue(clear.isEnabled)
        XCTAssertTrue(app.staticTexts["legacy-cache-delay"].firstMatch.exists)
        capture("Cache Settings", in: app)
        clear.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cache-result"].firstMatch
            .waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(clear.exists)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(cache.waitForExistence(timeout: 8))
        cache.tap()
        XCTAssertTrue(app.staticTexts["cache-empty"].firstMatch.waitForExistence(timeout: 8))

        for (identifier, options) in [("cache-preview-limit", ["8 MiB", "16 MiB", "32 MiB"]),
                                      ("cache-nested-limit", ["64 MiB", "128 MiB", "256 MiB"])] {
            let picker = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
            let original = try XCTUnwrap(picker.value as? String)
            let requested = try XCTUnwrap(options.first { $0 != original })
            picker.tap()
            app.buttons[requested].firstMatch.tap()
            XCTAssertEqual(picker.value as? String, requested, picker.debugDescription)
            if options.contains(original) {
                picker.tap()
                app.buttons[original].firstMatch.tap()
            }
        }
    }

    func testArchivePreviewRespectsConfiguredCacheLimit() {
        let app = XCUIApplication()
        app.launchArguments = ["-previewLimitMiB", "8", "-destinationPolicy", "2"]
        app.launch()
        openWorkspaceArchive("Cache Limit.zip", in: app)
        let preview = app.buttons["Preview large.txt"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8), app.debugDescription)
        preview.tap()
        XCTAssertTrue(app.staticTexts["This file exceeds the preview limits."].firstMatch
            .waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["preview-file-size"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["preview-capacity-limit"].firstMatch.label.contains("8 MiB"))
        app.buttons["extract-preview-file"].firstMatch.tap()
        let placement = app.staticTexts["extraction-placement-detail"].firstMatch
        XCTAssertTrue(placement.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(placement.label, "Place the file directly in the destination.")
        confirmExtraction(in: app)
        let reveal = app.buttons["view-extraction-folder"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 12), app.debugDescription)
        reveal.tap()
        let clear = app.buttons["clear-workspace-search"].firstMatch
        if clear.exists { clear.tap() }
        _ = workspaceFile(named: "large.txt", in: app)
        XCTAssertFalse(app.buttons["workspace-file-preview-companion.txt"].firstMatch.exists)
    }

    func testSettingsDestination() {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app, title: "Settings")
        let destination = app.buttons["settings-destination"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 8), app.debugDescription)
        let original = destination.value as? String ?? "Ask each time"
        let other = original == "App Documents" ? "Ask each time" : "App Documents"
        capture("Settings Overview", in: app)
        destination.tap()
        XCTAssertTrue(app.buttons[other].firstMatch.waitForExistence(timeout: 8))
        capture("Destination Preferences", in: app)
        app.buttons[other].firstMatch.tap()
        XCTAssertEqual(destination.value as? String, other)
        destination.tap()
        app.buttons[original].firstMatch.tap()
    }

    func testAboutShowsBuildInformationAndLicenseNotices() {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app, title: "Settings")
        let about = app.buttons["settings-about"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue((about.value as? String)?.hasPrefix("Version ") == true)
        about.tap()

        for id in ["about-app-version", "about-build", "about-core-version"] {
            let value = app.staticTexts[id].firstMatch
            XCTAssertTrue(value.waitForExistence(timeout: 8), app.debugDescription)
            let announcement = value.label + (value.value as? String ?? "")
            XCTAssertTrue(announcement.contains(where: \.isNumber), value.debugDescription)
        }
        capture("About AetherUnzip", in: app)
        let copy = app.buttons["about-copy-versions"].firstMatch
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")

        app.buttons["about-licenses"].firstMatch.tap()
        let project = app.buttons["license-LICENSE"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(project.label.contains("GPL-3.0-only"), project.debugDescription)
        let library = app.buttons["license-liblzma"].firstMatch
        XCTAssertTrue(library.exists)
        capture("License Notices", in: app)
        project.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "GNU GENERAL PUBLIC LICENSE"))
            .firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        app.navigationBars["AetherUnzip"].buttons.firstMatch.tap()
        XCTAssertTrue(library.waitForExistence(timeout: 8), app.debugDescription)
        library.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Permission to use, copy, modify"))
            .firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testAboutShowsSupportedExtractionFormats() {
        let app = XCUIApplication()
        app.launch()
        openSettings(in: app, title: "Settings")
        let about = app.buttons["settings-about"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 8), app.debugDescription)
        capture("Settings Colors", in: app)
        about.tap()
        let formats = app.buttons["about-formats"].firstMatch
        XCTAssertTrue(formats.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Extraction Support"].firstMatch.exists)
        capture("About Extraction Support", in: app)
        formats.tap()

        let zip = app.descendants(matching: .any)["supported-format-1"].firstMatch
        XCTAssertTrue(zip.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(zip.label.contains("ZIP / ZIP64"))
        XCTAssertTrue(zip.label.contains("WinZip AES-256"))
        XCTAssertEqual(zip.value as? String, "Supported")
        capture("Supported Archive Formats", in: app)
        let xp3 = app.descendants(matching: .any)["supported-format-15"].firstMatch
        for _ in 0..<4 where !xp3.isHittable { app.swipeUp() }
        XCTAssertTrue(xp3.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(xp3.label.contains("KiriKiri"))
        XCTAssertEqual(xp3.value as? String, "Supported")
        app.navigationBars["Supported Formats"].buttons.firstMatch.tap()
        XCTAssertTrue(formats.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testSettingsAskDestinationUsesNativeFolderPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-conflictPolicy", "2"]
        app.launch()
        openSettings(in: app, title: "Settings")
        let destination = app.buttons["settings-destination"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 8), app.debugDescription)
        let original = destination.value as? String
        destination.tap()
        app.buttons["Ask each time"].firstMatch.tap()
        XCTAssertEqual(destination.value as? String, "Ask each time")

        openWorkspacePage("Files", sidebarID: "archives", in: app)
        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("MobileSample.zip")
        app.buttons["workspace-file-MobileSample.zip"].firstMatch.tap()
        let extract = app.buttons["extract-all"].firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 8))
        extract.tap()
        let choose = app.buttons["extraction-choose-folder"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["confirm-extraction-plan"].firstMatch.isEnabled)
        choose.tap()
        pickFromFiles("AetherUnzip Settings Output", in: app)
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(app.staticTexts["Extraction completed in AetherUnzip Settings Output."].firstMatch
            .waitForExistence(timeout: 12), app.debugDescription)

        if let original, original != "Ask each time" {
            openSettings(in: app, title: "Settings")
            destination.tap()
            app.buttons[original].firstMatch.tap()
        }
    }

    private func openSettings(in app: XCUIApplication, title: String) {
        openWorkspacePage(title, sidebarID: "settings", in: app)
    }

    private func openWorkspacePage(_ title: String, sidebarID: String, in app: XCUIApplication) {
        let tabs = app.tabBars.firstMatch
        if tabs.exists {
            tabs.buttons[title].tap()
        } else {
            let page = app.descendants(matching: .any)["workspace-sidebar-\(sidebarID)"].firstMatch
            let sidebar = app.buttons["Show Sidebar"].firstMatch
            if !page.exists && sidebar.waitForExistence(timeout: 5) { sidebar.tap() }
            XCTAssertTrue(page.waitForExistence(timeout: 8), app.debugDescription)
            page.tap()
        }
    }

    private func replaceLimit(_ field: XCUIElement, in app: XCUIApplication, with value: String) {
        field.tap()
        app.buttons["settings-limit-clear-file"].firstMatch.tap()
        field.typeText(value)
    }

    func testSimplifiedChineseSettings() {
        checkSettings(language: "zh-Hans", locale: "zh_CN", settings: "设置", safety: "安全限制", file: "单个文件",
                      about: "关于以太解压", appName: "以太解压", build: "构建编号", licenses: "开源许可证")
    }

    func testJapaneseSettings() {
        checkSettings(language: "ja", locale: "ja_JP", settings: "設定", safety: "安全上限", file: "ファイル単位",
                      about: "AetherUnzip について", appName: "AetherUnzip",
                      build: "ビルド番号", licenses: "オープンソースライセンス")
    }

    private func checkSettings(language: String, locale: String, settings: String, safety: String, file: String,
                               about: String, appName: String, build: String, licenses: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        openSettings(in: app, title: settings)
        let row = app.buttons["settings-safety"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(row.label, safety)
        capture("Settings \(language)", in: app)
        row.tap()
        let field = app.textFields["settings-limit-file"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts[file].firstMatch.exists)
        capture("Safety Limits \(language)", in: app)
        app.buttons[language == "ja" ? "キャンセル" : "取消"].firstMatch.tap()
        let aboutRow = app.buttons["settings-about"].firstMatch
        XCTAssertTrue(aboutRow.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(aboutRow.label, about)
        aboutRow.tap()
        let identity = app.descendants(matching: .any)["about-app-identity"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(identity.label.contains(appName), identity.debugDescription)
        let buildRow = app.staticTexts["about-build"].firstMatch
        XCTAssertTrue(buildRow.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(buildRow.label.contains(build), buildRow.debugDescription)
        XCTAssertEqual(app.buttons["about-licenses"].firstMatch.label, licenses)
        capture("About \(language)", in: app)
    }

    func testEnglishLocalization() {
        checkLocalization(language: "en", locale: "en_US", filesTitle: "My Files", searchTitle: "Search this folder",
                          sortTitle: "Sort By", dateTitle: "Date Modified", itemCount: "1 item",
                          passwordTitle: "Archive Password", passwordError: "The password is incorrect or the encrypted data is damaged")
    }

    func testSimplifiedChineseLocalization() {
        checkLocalization(language: "zh-Hans", locale: "zh_CN", filesTitle: "我的文件", searchTitle: "搜索此文件夹",
                          sortTitle: "排序方式", dateTitle: "修改日期", itemCount: "1 项",
                          passwordTitle: "压缩包密码", passwordError: "密码不正确，或加密数据已损坏")
    }

    func testJapaneseLocalization() {
        checkLocalization(language: "ja", locale: "ja_JP", filesTitle: "マイファイル", searchTitle: "このフォルダ内を検索",
                          sortTitle: "並べ替え", dateTitle: "変更日", itemCount: "1 項目",
                          passwordTitle: "アーカイブのパスワード", passwordError: "パスワードが違うか、暗号化データが破損しています")
    }

    private func checkLocalization(language: String, locale: String, filesTitle: String, searchTitle: String,
                                   sortTitle: String, dateTitle: String, itemCount: String,
                                   passwordTitle: String, passwordError: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()

        let root = app.buttons["file-path-0"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 8))
        XCTAssertEqual(root.label, filesTitle)
        let sort = app.buttons["workspace-sort"].firstMatch
        XCTAssertEqual(sort.label, sortTitle)
        sort.tap()
        XCTAssertTrue(app.buttons[dateTitle].firstMatch.waitForExistence(timeout: 8))
        capture("Sort \(language)", in: app)
        app.buttons["workspace-sort-done"].firstMatch.tap()

        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertEqual(search.placeholderValue, searchTitle)
        search.tap()
        search.typeText("MobileProtectedRAR.rar")
        XCTAssertTrue(app.staticTexts[itemCount].firstMatch.waitForExistence(timeout: 8))
        app.buttons["workspace-file-MobileProtectedRAR.rar"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[passwordTitle].firstMatch.waitForExistence(timeout: 8))
        let password = app.secureTextFields["archive-password"].firstMatch
        password.tap()
        password.typeText("wrong-password")
        app.buttons["submit-archive-password"].firstMatch.tap()
        let error = app.staticTexts["archive-password-error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8))
        XCTAssertEqual(error.label, passwordError)
        capture("Password \(language)", in: app)
    }

    func testArchiveAndWorkspacePageLayouts() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "1", "-conflictPolicy", "2"]
        app.launch()

        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("Project Downloads")
        let folder = app.buttons["workspace-file-Project Downloads"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        folder.tap()
        let tar = app.buttons["workspace-file-Release Backup.tar.gz"].firstMatch
        XCTAssertTrue(tar.waitForExistence(timeout: 8))
        tar.tap()

        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@",
                                                           "TAR · GZIP", "1 item")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["Preview notes.txt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["./"].exists)
        XCTAssertTrue(app.buttons["extract-all"].firstMatch.isHittable)
        capture("Archive Preview", in: app)

        app.buttons["extract-all"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(app.staticTexts["Extraction completed in Extracted Archives."].firstMatch
            .waitForExistence(timeout: 10), app.debugDescription)

        openWorkspacePage("Activity", sidebarID: "activity", in: app)
        XCTAssertTrue(app.staticTexts["Recently Opened"].firstMatch.waitForExistence(timeout: 8))
        let recent = app.buttons["activity-recent-Release Backup.tar.gz"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 8), app.debugDescription)
        capture("Activity", in: app)
        let showRecents = app.buttons["activity-toggle-recents"].firstMatch
        if showRecents.isHittable {
            showRecents.tap()
            if !showRecents.isHittable { app.swipeUp() }
            XCTAssertTrue(showRecents.waitForExistence(timeout: 8))
            XCTAssertEqual(showRecents.label, "Show Fewer Recent Archives")
            showRecents.tap()
        }
        if !recent.isHittable { app.swipeDown() }
        recent.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 8), app.debugDescription)

        openWorkspacePage("Activity", sidebarID: "activity", in: app)
        let extraction = app.staticTexts["activity-extraction-Release Backup.tar.gz"].firstMatch
        let lowerList = app.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.72))
        let upperList = app.coordinate(withNormalizedOffset: CGVector(dx: 0.66, dy: 0.45))
        for _ in 0..<5 where !extraction.exists {
            lowerList.press(forDuration: 0.05, thenDragTo: upperList, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTAssertTrue(extraction.waitForExistence(timeout: 8), app.debugDescription)

        openSettings(in: app, title: "Settings")
        let limits = app.buttons["settings-safety"].firstMatch
        XCTAssertTrue(limits.waitForExistence(timeout: 8), app.debugDescription)
        capture("Settings", in: app)
        limits.tap()
        XCTAssertTrue(app.textFields["settings-limit-file"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    private func capture(_ title: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFileWorkspaceNavigatesExtractsAndRevealsOutput() {
        let app = XCUIApplication()
        app.launch()
        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), app.debugDescription)
        search.tap()
        search.typeText("Project Downloads")
        let folder = app.buttons["workspace-file-Project Downloads"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
        let archive = app.buttons["workspace-file-Project Assets.zip"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 8), app.debugDescription)
        let sort = app.buttons["workspace-sort"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 8), app.debugDescription)
        sort.tap()
        app.buttons["Kind"].firstMatch.tap()
        let descending = app.buttons["workspace-sort-descending"].firstMatch
        XCTAssertTrue(descending.waitForExistence(timeout: 8))
        descending.tap()
        capture("Sort Options", in: app)
        app.buttons["workspace-sort-done"].firstMatch.tap()
        XCTAssertEqual(sort.value as? String, "Kind, Descending")

        let listing = XCTAttachment(screenshot: app.screenshot())
        listing.name = "Compact folder listing"
        listing.lifetime = .keepAlways
        add(listing)

        XCTAssertTrue(search.waitForExistence(timeout: 8), app.debugDescription)
        search.tap()
        search.typeText("Project Assets.zip")
        XCTAssertTrue(app.staticTexts["1 item"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(archive.isHittable)
        capture("Active Search", in: app)
        app.buttons["workspace-search-done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 item"].firstMatch.exists)
        app.buttons["clear-workspace-search"].firstMatch.tap()
        archive.tap()
        let destinations = app.buttons["archive-extract-destinations"].firstMatch
        XCTAssertTrue(destinations.waitForExistence(timeout: 8), app.debugDescription)
        destinations.tap()
        let newFolder = app.buttons["Extract to New Folder"].firstMatch
        XCTAssertTrue(newFolder.waitForExistence(timeout: 8), app.debugDescription)
        capture("Extraction Destination", in: app)
        newFolder.tap()
        confirmExtraction(in: app)
        let reveal = app.buttons["view-extraction-folder"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 12), app.debugDescription)
        reveal.tap()
        let note = app.buttons["workspace-file-notes.txt"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Extracted folder in Files"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["file-actions"].firstMatch.tap()
        app.buttons["select-workspace-files"].firstMatch.tap()
        let selectionCount = app.staticTexts["1 selected"].firstMatch
        note.tap()
        XCTAssertTrue(selectionCount.waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["finish-file-selection"].firstMatch.tap()
        XCTAssertTrue(selectionCount.waitForNonExistence(timeout: 8), app.debugDescription)
        let parent = app.buttons["parent-file-folder"].firstMatch
        XCTAssertTrue(parent.exists)
        parent.tap()
        XCTAssertTrue(archive.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testFileWorkspaceCreatesFolderAndNavigatesBack() {
        let app = XCUIApplication()
        app.launch()
        let menu = app.buttons["file-actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), app.debugDescription)
        menu.tap()
        app.buttons["new-file-folder"].firstMatch.tap()
        let field = app.textFields["workspace-file-name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        let name = "New Folder \(UUID().uuidString.prefix(6))"
        field.tap()
        field.typeText("invalid/name")
        let save = app.buttons["workspace-save-name"].firstMatch
        XCTAssertTrue(app.staticTexts["workspace-name-error"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(save.isEnabled)
        capture("Folder Name Validation", in: app)
        app.buttons["workspace-clear-name"].firstMatch.tap()
        field.typeText(name)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let row = app.buttons["workspace-file-\(name)"].firstMatch
        if !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.staticTexts["This Folder Is Empty"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["parent-file-folder"].firstMatch.tap()
        XCTAssertTrue(app.buttons["file-path-0"].firstMatch.waitForExistence(timeout: 8))
    }

    func testCreatesMarkdownAndSavesEditsInPlace() {
        let app = XCUIApplication()
        app.launch()
        let name = "Notes \(UUID().uuidString.prefix(6))"
        newWorkspaceFile(named: name, format: "Markdown (.md)", in: app)
        app.buttons["workspace-new-file-create"].firstMatch.tap()

        let text = workspaceEditor(in: app)
        text.tap()
        text.typeText("Saved draft")
        let save = app.buttons["workspace-editor-save"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 8))
        capture("Text Editor", in: app)

        text.tap()
        text.typeText(" unsaved")
        app.buttons["workspace-editor-done"].firstMatch.tap()
        let discard = app.buttons["Discard Changes"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 8))
        discard.tap()

        workspaceFile(named: name + ".md", in: app).tap()
        XCTAssertEqual(workspaceEditor(in: app).value as? String, "Saved draft")
    }

    func testCreatesAndReopensCustomTextFile() {
        let app = XCUIApplication()
        app.launch()
        let name = "Custom \(UUID().uuidString.prefix(6))"
        newWorkspaceFile(named: name, format: "Custom Extension", in: app)
        let suffix = app.textFields["workspace-new-file-extension"].firstMatch
        XCTAssertTrue(suffix.waitForExistence(timeout: 8), app.debugDescription)
        let create = app.buttons["workspace-new-file-create"].firstMatch
        XCTAssertFalse(create.isEnabled)
        suffix.tap()
        suffix.typeText("no/slash")
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(app.staticTexts["workspace-new-file-error"].firstMatch.exists)
        suffix.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "no/slash".count) + ".aunote")
        XCTAssertTrue(create.isEnabled)
        capture("New Custom File", in: app)
        create.tap()

        let text = workspaceEditor(in: app)
        text.tap()
        text.typeText("Custom contents")
        let save = app.buttons["workspace-editor-save"].firstMatch
        save.tap()
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: false, timeout: 8))
        app.buttons["workspace-editor-done"].firstMatch.tap()

        workspaceFile(named: name + ".aunote", in: app).press(forDuration: 1)
        let edit = app.buttons["edit-workspace-text"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 8), app.debugDescription)
        edit.tap()
        XCTAssertEqual(workspaceEditor(in: app).value as? String, "Custom contents")
    }

    private func newWorkspaceFile(named name: String, format: String, in app: XCUIApplication) {
        let menu = app.buttons["file-actions"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), app.debugDescription)
        menu.tap()
        app.buttons["new-workspace-file"].firstMatch.tap()
        let field = app.textFields["workspace-new-file-name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        field.tap()
        field.typeText(name)
        app.buttons["workspace-new-file-format"].firstMatch.tap()
        let option = app.buttons[format].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8), app.debugDescription)
        option.tap()
    }

    private func workspaceEditor(in app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["workspace-editor-text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        return field
    }

    private func chooseExtractionLayout(_ name: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["extraction-layout"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8), app.debugDescription)
        option.tap()
    }

    private func confirmExtraction(in app: XCUIApplication, layout: String? = nil) {
        if let layout { chooseExtractionLayout(layout, in: app) }
        let confirm = app.buttons["confirm-extraction-plan"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(confirm.isEnabled, app.debugDescription)
        confirm.tap()
    }

    func testExtractionLayoutPreviewsAndKeepsBothAfterRemovingTopFolder() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "2", "-conflictPolicy", "3"]
        app.launch()
        workspaceFile(named: "Layout Workflow", in: app).tap()
        workspaceFile(named: "Top Layout.zip", in: app).tap()
        let extract = app.buttons["extract-all"].firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 8), app.debugDescription)
        extract.tap()
        let path = app.descendants(matching: .any)["extraction-output-path"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(path.label.contains("Layout Workflow › Layout"), path.debugDescription)
        XCTAssertTrue(app.staticTexts["extraction-placement-detail"].label.contains("Keep the archive’s top folder"))
        capture("Smart Extraction Preview", in: app)

        chooseExtractionLayout("Extract Directly", in: app)
        XCTAssertTrue(path.label.contains("Layout Workflow › Layout"), path.debugDescription)
        chooseExtractionLayout("Separate Folder", in: app)
        XCTAssertTrue(path.label.contains("Layout Workflow › Top Layout"), path.debugDescription)
        chooseExtractionLayout("Remove Top Folder", in: app)
        XCTAssertTrue(path.label.hasSuffix("Layout Workflow"), path.debugDescription)
        XCTAssertTrue(app.staticTexts["extraction-placement-detail"].label.contains("Remove “Layout”"))
        confirmExtraction(in: app)
        let reveal = app.buttons["view-extraction-folder"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 12), app.debugDescription)
        reveal.tap()
        XCTAssertTrue(app.buttons["workspace-file-notes (2).txt"].firstMatch
            .waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["workspace-file-notes.txt"].firstMatch.exists)
    }

    func testBatchExtractsTwoArchivesAndReportsUnreadableInput() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "2", "-conflictPolicy", "3"]
        app.launch()
        workspaceFile(named: "Batch Workflow", in: app).tap()
        selectBatch(["Batch First.zip", "Batch Second.tar.gz", "Batch Corrupt.zip"], in: app)
        let path = app.descendants(matching: .any)["extraction-output-path"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(path.label.contains("Batch Workflow › Batch First"), path.debugDescription)
        let skipped = app.descendants(matching: .any)["extraction-skipped"].firstMatch
        XCTAssertTrue(skipped.exists, app.debugDescription)
        capture("Batch Extraction Preview", in: app)
        skipped.tap()
        let reason = app.staticTexts["Archive format could not be identified"].firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "extraction-skipped", "Batch Corrupt.zip")).firstMatch.exists)
        confirmExtraction(in: app)
        XCTAssertTrue(app.staticTexts["2 of 3 archives extracted."].firstMatch.waitForExistence(timeout: 12),
                      app.debugDescription)
        app.buttons["view-batch-results"].firstMatch.tap()
        let open = app.buttons["batch-output-Batch Second.tar.gz"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["batch-retry-Batch Corrupt.zip"].firstMatch.exists)
        XCTAssertFalse(app.buttons["batch-retry-Batch Second.tar.gz"].firstMatch.exists)
        open.tap()
        XCTAssertTrue(app.buttons["workspace-file-notes.txt"].firstMatch.waitForExistence(timeout: 8))
    }

    func testBatchRecoveryRetriesOnlyTheLockedArchive() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "2", "-conflictPolicy", "3"]
        app.launch()
        workspaceFile(named: "Batch Recovery", in: app).tap()
        selectBatch(["Recovery First.zip", "Recovery Locked.7z"], in: app)
        let ready = app.buttons["confirm-extraction-plan"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["extraction-skipped"].firstMatch.waitForExistence(timeout: 8))
        confirmExtraction(in: app)
        let results = app.buttons["view-batch-results"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 12), app.debugDescription)
        results.tap()

        let retry = app.buttons["batch-retry-Recovery Locked.7z"].firstMatch
        let firstOutput = app.buttons["batch-output-Recovery First.zip"].firstMatch
        let recovered = app.buttons["batch-output-Recovery Locked.7z"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(firstOutput.exists)
        for password in ["wrong-password", "fixture-pass"] {
            XCTAssertTrue(retry.waitForExistence(timeout: 8))
            retry.tap()
            let field = app.secureTextFields["archive-password"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 8))
            field.tap()
            field.typeText(password)
            let remember = app.switches["remember-archive-password"].firstMatch
            if remember.value as? String == "1" { remember.tap() }
            app.buttons["submit-archive-password"].firstMatch.tap()
            if password == "wrong-password" {
                XCTAssertTrue(retry.waitForExistence(timeout: 8))
                XCTAssertFalse(recovered.exists)
            }
        }
        XCTAssertTrue(recovered.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(firstOutput.exists)
        recovered.tap()
        XCTAssertTrue(app.buttons["workspace-file-private.txt"].firstMatch.waitForExistence(timeout: 8))
    }

    private func selectBatch(_ names: [String], in app: XCUIApplication) {
        let actions = app.buttons["file-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 8), app.debugDescription)
        actions.tap()
        app.buttons["select-workspace-files"].firstMatch.tap()
        for name in names {
            let file = app.buttons["workspace-file-\(name)"].firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
            file.tap()
        }
        app.buttons["workspace-selection-actions"].firstMatch.tap()
        let selected = app.buttons["extract-workspace-selection"].firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 8), app.debugDescription)
        selected.tap()
    }

    private func workspaceFile(named name: String, in app: XCUIApplication) -> XCUIElement {
        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), app.debugDescription)
        search.tap()
        search.typeText(name)
        let row = app.buttons["workspace-file-\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
        return row
    }

    func testRecognitionPreviewsRenamesAndExtractsJPEGWithZIP() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "1", "-conflictPolicy", "2"]
        app.launch()
        let photo = workspaceFile(named: "Recognition Hybrid.jpg", in: app)
        app.buttons["workspace-search-done"].firstMatch.tap()
        photo.tap()
        XCTAssertTrue(app.otherElements["QLPreviewControllerView"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)
        app.terminate()
        app.launch()

        identifyArchive(workspaceFile(named: "Recognition Hybrid.jpg", in: app), in: app)
        checkRecognitionValue("recognition-original-name", contains: "Recognition Hybrid.jpg", in: app)
        checkRecognitionValue("recognition-format", contains: "ZIP", in: app)
        checkRecognitionValue("recognition-suggested-name", contains: "Recognition Hybrid.zip", in: app)
        capture("Archive Identification", in: app)
        app.buttons["recognition-cancel"].firstMatch.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 8))

        identifyArchive(photo, in: app)
        let rename = app.buttons["recognition-rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8), app.debugDescription)
        rename.tap()
        let extract = app.buttons["extract-all"].firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Recognition Hybrid.zip"].firstMatch.exists)
        extract.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(app.staticTexts["Extraction completed in Extracted Archives."].firstMatch
            .waitForExistence(timeout: 12), app.debugDescription)
    }

    func testRecognitionRejectsNormalJPEGAndOpensZIPWithoutRenaming() {
        let app = XCUIApplication()
        app.launch()
        identifyArchive(workspaceFile(named: "Recognition Photo.jpg", in: app), in: app)
        XCTAssertTrue(app.staticTexts["recognition-error"].firstMatch.waitForExistence(timeout: 8),
                      app.debugDescription)
        XCTAssertFalse(app.buttons["recognition-rename"].exists)
        XCTAssertFalse(app.buttons["recognition-open"].exists)
        app.buttons["recognition-cancel"].firstMatch.tap()
        app.buttons["clear-workspace-search"].firstMatch.tap()

        let archive = workspaceFile(named: "Recognition Copy.mp3", in: app)
        identifyArchive(archive, in: app)
        checkRecognitionValue("recognition-suggested-name", contains: "Recognition Copy.zip", in: app)
        app.buttons["recognition-open"].firstMatch.tap()
        XCTAssertTrue(app.buttons["extract-all"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Recognition Copy.mp3"].firstMatch.exists)
    }

    func testRecognitionShowsBothTARAndItsCompression() {
        let app = XCUIApplication()
        app.launch()
        identifyArchive(workspaceFile(named: "Recognition Backup.mp4", in: app), in: app)
        checkRecognitionValue("recognition-format", contains: "TAR · GZIP", in: app)
        checkRecognitionValue("recognition-suggested-name", contains: "Recognition Backup.tar.gz", in: app)
    }

    func testRecognitionUsesTheExistingPasswordPrompt() {
        let app = launchWithIsolatedPasswordLibrary()
        identifyArchive(workspaceFile(named: "Recognition Locked.jpg", in: app), in: app)
        let open = app.buttons["recognition-open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["recognition-rename"].exists)
        open.tap()
        let password = app.secureTextFields["archive-password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 8), app.debugDescription)
        password.tap()
        password.typeText("fixture-pass")
        app.buttons["submit-archive-password"].firstMatch.tap()
        XCTAssertTrue(app.buttons["extract-all"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Recognition Locked.jpg"].firstMatch.exists)
    }

    private func identifyArchive(_ row: XCUIElement, in app: XCUIApplication) {
        row.press(forDuration: 1)
        let identify = app.buttons["identify-workspace-archive"].firstMatch
        XCTAssertTrue(identify.waitForExistence(timeout: 8), app.debugDescription)
        identify.tap()
    }

    private func checkRecognitionValue(_ identifier: String, contains expected: String, in app: XCUIApplication) {
        let value = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue([value.label, value.value as? String ?? ""].joined(separator: " ").contains(expected),
                      value.debugDescription)
    }

    func testBrowseAndSelectAcrossFolders() {
        let app = XCUIApplication()
        app.launch()
        openWorkspaceArchive("MobileSample.zip", in: app)

        let select = app.buttons["select-entries"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 10), app.debugDescription)
        select.tap()
        app.buttons["archive-entry-0"].firstMatch.tap()

        let folder = app.buttons["directory:/docs"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8), app.debugDescription)
        folder.tap()
        let readme = app.buttons["archive-entry-1"].firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 8), app.debugDescription)
        readme.tap()
        XCTAssertTrue(app.buttons["extract-selected"].firstMatch.label.contains("2"))

        app.buttons["archive-folder-up"].firstMatch.tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 8))
        let search = app.textFields["archive-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("docs/readme.txt")
        XCTAssertTrue(readme.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["archive-entry-0"].exists)
    }

    func testUnlockSevenZipFromFiles() {
        checkUnlockFromFiles("MobileProtected.7z")
    }

    func testRemembersArchivePasswordAfterRelaunchAndRename() {
        let app = launchWithIsolatedPasswordLibrary()
        openWorkspacePage("Passwords", sidebarID: "passwords", in: app)
        XCTAssertTrue(app.staticTexts["No Saved Passwords"].firstMatch.waitForExistence(timeout: 8))
        openWorkspacePage("Files", sidebarID: "archives", in: app)
        openWorkspaceArchive("Library Locked.rar", in: app)
        let field = app.secureTextFields["archive-password"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        field.tap()
        field.typeText("fixture-pass")
        app.buttons["submit-archive-password"].firstMatch.tap()
        XCTAssertTrue(app.buttons["extract-all"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        openWorkspacePage("Passwords", sidebarID: "passwords", in: app)
        XCTAssertTrue(app.staticTexts["Library Locked.rar"].firstMatch.waitForExistence(timeout: 8))

        app.terminate()
        app.launch()
        openWorkspaceArchive("Library Renamed.rar", in: app)
        XCTAssertTrue(app.buttons["extract-all"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(field.exists)
    }

    func testSelectsAndTriesPasswordsFromLibrary() {
        let app = launchWithIsolatedPasswordLibrary()
        openWorkspacePage("Passwords", sidebarID: "passwords", in: app)
        addLibraryPassword("fixture-pass", named: "Fixture Password", in: app)
        addLibraryPassword("wrong-password", named: "Other Password", in: app)
        capture("Password Library", in: app)
        openWorkspacePage("Files", sidebarID: "archives", in: app)
        openWorkspaceArchive("Library Payload.zip", in: app)

        let choose = app.buttons["choose-saved-password"].firstMatch
        let all = app.buttons["try-password-library"].firstMatch
        let completion = app.staticTexts["Extraction completed in Extracted Archives."].firstMatch
        app.buttons["extract-all"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        choose.tap()
        XCTAssertTrue(all.waitForExistence(timeout: 8), app.debugDescription)
        all.tap()
        XCTAssertTrue(completion.waitForExistence(timeout: 12), app.debugDescription)

        app.terminate()
        app.launch()
        openWorkspaceArchive("Library Payload.zip", in: app)
        app.buttons["extract-all"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(completion.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(choose.exists)

        let explicit = app.buttons["extract-with-password"].firstMatch
        XCTAssertTrue(explicit.waitForExistence(timeout: 8), app.debugDescription)
        explicit.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        choose.tap()
        let saved = app.buttons["Fixture Password"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8), app.debugDescription)
        saved.tap()
        XCTAssertTrue(completion.waitForExistence(timeout: 12), app.debugDescription)
    }

    func testPastesExactChinesePasswordAndRemembersItAfterRename() {
        let app = launchWithIsolatedPasswordLibrary()
        let password = " 资源密碼！Ａ1 "

        openWorkspaceArchive("Chinese Vault.zip", in: app)
        app.buttons["extract-all"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Separate Folder")

        let masked = app.secureTextFields["archive-password"].firstMatch
        XCTAssertTrue(masked.waitForExistence(timeout: 8), app.debugDescription)
        let paste = app.buttons["archive-password-paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(paste.isEnabled, "Seed the simulator pasteboard with the fixture password.")
        paste.tap()

        let eye = app.buttons["archive-password-visibility"].firstMatch
        eye.tap()
        let visible = app.textFields["archive-password"].firstMatch
        XCTAssertTrue(visible.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(visible.value as? String, password)
        eye.tap()
        XCTAssertTrue(masked.waitForExistence(timeout: 8))
        app.buttons["submit-archive-password"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Extraction completed in Chinese Vault."].firstMatch
            .waitForExistence(timeout: 12), app.debugDescription)

        app.terminate()
        app.launch()
        openWorkspaceArchive("Chinese Vault Renamed.zip", in: app)
        app.buttons["extract-all"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Separate Folder")
        XCTAssertTrue(app.staticTexts["Extraction completed in Chinese Vault Renamed."].firstMatch
            .waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertFalse(masked.exists)
    }

    private func launchWithIsolatedPasswordLibrary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = passwordLibraryArguments + ["-destinationPolicy", "1", "-conflictPolicy", "2"]
        app.launch()
        return app
    }

    private var passwordLibraryArguments: [String] { ["-PasswordLibraryTestNamespace", UUID().uuidString] }

    private func openWorkspaceArchive(_ name: String, in app: XCUIApplication) {
        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), app.debugDescription)
        search.tap()
        search.typeText(name)
        let archive = app.buttons["workspace-file-\(name)"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 8), app.debugDescription)
        archive.tap()
    }

    private func addLibraryPassword(_ password: String, named name: String, in app: XCUIApplication) {
        let add = app.buttons["password-library-add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), app.debugDescription)
        add.tap()
        let title = app.textFields["password-library-name"].firstMatch
        let value = app.secureTextFields["password-library-value"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        title.tap()
        title.typeText(name)
        value.tap()
        value.typeText(password)
        app.buttons["password-library-save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testUnlockRAR5FromFiles() {
        let app = XCUIApplication()
        app.launchArguments = passwordLibraryArguments + ["-destinationPolicy", "1", "-conflictPolicy", "2"]
        app.launch()
        unlockFromFiles("MobileProtectedRAR.rar", previewing: "rar5-picker-note.txt", in: app,
                        checksWrongPassword: true)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["extract-all"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(app.staticTexts["Extraction completed in Extracted Archives."]
            .waitForExistence(timeout: 10), app.debugDescription)
    }

    func testExtractSelectedEncryptedSolidRAR5FromFiles() {
        let app = XCUIApplication()
        app.launchArguments = passwordLibraryArguments + ["-destinationPolicy", "1", "-conflictPolicy", "2"]
        app.launch()
        unlockFromFiles("MobileSolidRAR.rar", previewing: "third.txt", in: app)
        app.buttons["Done"].firstMatch.tap()
        let select = app.buttons["select-entries"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 8), app.debugDescription)
        select.tap()
        let entry = app.buttons["archive-entry-2"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8), app.debugDescription)
        entry.tap()
        app.buttons["extract-selected"].firstMatch.tap()
        confirmExtraction(in: app, layout: "Extract Directly")
        XCTAssertTrue(app.staticTexts["Extraction completed in Extracted Archives."]
            .waitForExistence(timeout: 10), app.debugDescription)
    }

    private func checkUnlockFromFiles(_ name: String) {
        let app = XCUIApplication()
        app.launchArguments = passwordLibraryArguments
        app.launch()
        unlockFromFiles(name, previewing: "private.txt", in: app)
    }

    private func unlockFromFiles(_ name: String, previewing entry: String, in app: XCUIApplication,
                                 checksWrongPassword: Bool = false) {
        openFromFiles(name, in: app)
        let password = app.secureTextFields["archive-password"].firstMatch
        let submit = app.buttons["submit-archive-password"].firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 8), app.debugDescription)
        if checksWrongPassword {
            password.tap()
            password.typeText("wrong-password")
            let visibility = app.buttons["archive-password-visibility"].firstMatch
            visibility.tap()
            let revealed = app.textFields["archive-password"].firstMatch
            XCTAssertTrue(revealed.waitForExistence(timeout: 8))
            XCTAssertEqual(revealed.value as? String, "wrong-password")
            visibility.tap()
            XCTAssertTrue(password.waitForExistence(timeout: 8))
            submit.tap()
            let message = app.staticTexts["archive-password-error"].firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            capture("Archive Password Retry", in: app)
        } else {
            password.tap()
        }
        password.typeText("fixture-pass")
        submit.tap()
        let preview = app.buttons["Preview \(entry)"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), app.debugDescription)
        preview.tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.secureTextFields["preview-password"].exists)
    }

    func testOpenWithFormatProfileFromFiles() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-archive"].firstMatch.waitForExistence(timeout: 10))
        let profileAction = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "open-format-profile", "Open with Format Profile…")).firstMatch
        if !profileAction.exists || !profileAction.isHittable {
            let more = app.buttons["file-actions"].firstMatch
            if more.waitForExistence(timeout: 4) { more.tap() }
        }
        XCTAssertTrue(profileAction.waitForExistence(timeout: 8), app.debugDescription)
        profileAction.tap()
        pickFromFiles("MobileFormatProfile.json", in: app)
        let choose = app.buttons["choose-profile-archive"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        choose.tap()
        pickFromFiles("MobileProfileBox.bin", in: app)
        XCTAssertTrue(app.staticTexts["MobileProfileBox.bin"].waitForExistence(timeout: 10), app.debugDescription)
        let preview = app.buttons["Preview notes.txt"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        preview.tap()
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 8))
    }

    func testOpenXP3FromFiles() {
        let app = XCUIApplication()
        app.launch()
        openFromFiles("MobileResources.xp3", in: app)
        let format = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "XP3 ·")).firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 10), app.debugDescription)
        let preview = app.buttons["Preview notes.txt"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        preview.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.tap()
        XCTAssertTrue(format.exists)
    }

    func testOpenNestedArchiveFromFiles() {
        let app = XCUIApplication()
        app.launch()
        openFromFiles("MobileNested.zip", in: app)

        let firstChild = app.buttons["Open visible.zip as Archive"].firstMatch
        XCTAssertTrue(firstChild.waitForExistence(timeout: 10), app.debugDescription)
        firstChild.tap()
        let secondChild = app.buttons["Open deep.zip as Archive"].firstMatch
        XCTAssertTrue(secondChild.waitForExistence(timeout: 8))
        secondChild.tap()
        XCTAssertTrue(app.staticTexts["deep.zip"].waitForExistence(timeout: 8))
        let preview = app.buttons["Preview notes.txt"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        preview.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8))
        done.tap()
        let parent = app.buttons["parent-archive"].firstMatch
        parent.tap()
        XCTAssertTrue(app.staticTexts["visible.zip"].waitForExistence(timeout: 8))
        parent.tap()
        XCTAssertTrue(app.staticTexts["MobileNested.zip"].waitForExistence(timeout: 8))
    }

    private func openFromFiles(_ name: String, in app: XCUIApplication) {
        let open = app.buttons["open-archive"].firstMatch
        guard open.waitForExistence(timeout: 10) else {
            XCTFail(app.debugDescription)
            return
        }
        open.tap()
        pickFromFiles(name, in: app)
    }

    private func pickFromFiles(_ name: String, in app: XCUIApplication) {
        let fixtureCell = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", name)).firstMatch
        if !fixtureCell.exists {
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "浏览"])).firstMatch
            if browse.waitForExistence(timeout: 4) { browse.tap() }
            let local = app.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["On My iPhone", "On My iPad", "我的iPhone", "我的iPad", "我的 iPhone", "我的 iPad"])).firstMatch
            if local.waitForExistence(timeout: 4) { local.tap() }
            let folder = app.cells.matching(NSPredicate(format: "identifier IN %@",
                ["AetherUnzip, Container", "以太解压, Container", "以太解压, 容器"])).firstMatch
            if folder.waitForExistence(timeout: 4) { folder.tap() }
        }
        XCTAssertTrue(fixtureCell.waitForExistence(timeout: 8), app.debugDescription)
        fixtureCell.tap()
        let accept = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if accept.waitForExistence(timeout: 3) { accept.tap() }
    }
}
#endif
