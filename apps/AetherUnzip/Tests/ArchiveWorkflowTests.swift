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
        try pick(destination, in: app)
        XCTAssertTrue(app.staticTexts["Extraction completed in Output."].waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "notes.txt"), encoding: .utf8),
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
        try pick(destination, in: app)
        XCTAssertTrue(app.staticTexts["Extraction completed in Output."].waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "notes.txt"), encoding: .utf8),
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
        try pick(destination, in: app)

        XCTAssertTrue(app.staticTexts["Extraction completed in Output."].waitForExistence(timeout: 12))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "notes.txt"), encoding: .utf8),
                       "AetherUnzip fixture\n")
    }

    private func pick(_ url: URL, in app: XCUIApplication) throws {
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 8))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let field = panel.sheets.firstMatch.textFields["PathTextField"]
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

    func testSettingsDestinationAndLicenses() {
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

        app.buttons["settings-licenses"].firstMatch.tap()
        let project = app.buttons["AetherUnzip"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 8), app.debugDescription)
        project.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Permission is hereby granted"))
            .firstMatch.waitForExistence(timeout: 8), app.debugDescription)
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

        app.tabBars.firstMatch.buttons["Files"].tap()
        let search = app.textFields["workspace-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("MobileSample.zip")
        app.buttons["workspace-file-MobileSample.zip"].firstMatch.tap()
        let extract = app.buttons["extract-all"].firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 8))
        extract.tap()
        pickFromFiles("AetherUnzip Settings Output", in: app)
        XCTAssertTrue(app.staticTexts["Extraction completed in AetherUnzip Settings Output."].firstMatch
            .waitForExistence(timeout: 12), app.debugDescription)

        if original == "App Documents" {
            openSettings(in: app, title: "Settings")
            destination.tap()
            app.buttons["App Documents"].firstMatch.tap()
        }
    }

    private func openSettings(in app: XCUIApplication, title: String) {
        let tabs = app.tabBars.firstMatch
        if tabs.exists {
            tabs.buttons[title].tap()
        } else {
            let settings = app.descendants(matching: .any)["workspace-sidebar-settings"].firstMatch
            let sidebar = app.buttons["Show Sidebar"].firstMatch
            if !settings.exists && sidebar.waitForExistence(timeout: 5) { sidebar.tap() }
            XCTAssertTrue(settings.waitForExistence(timeout: 8), app.debugDescription)
            settings.tap()
        }
    }

    private func replaceLimit(_ field: XCUIElement, in app: XCUIApplication, with value: String) {
        field.tap()
        app.buttons["settings-limit-clear-file"].firstMatch.tap()
        field.typeText(value)
    }

    func testSimplifiedChineseSettings() {
        checkSettings(language: "zh-Hans", locale: "zh_CN", settings: "设置", safety: "安全限制", file: "单个文件")
    }

    func testJapaneseSettings() {
        checkSettings(language: "ja", locale: "ja_JP", settings: "設定", safety: "安全上限", file: "ファイル単位")
    }

    private func checkSettings(language: String, locale: String, settings: String, safety: String, file: String) {
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

        let tabs = app.tabBars.firstMatch
        if tabs.exists {
            tabs.buttons["Recents"].tap()
            XCTAssertTrue(app.staticTexts["Release Backup.tar.gz"].firstMatch.waitForExistence(timeout: 8))
            capture("Recents", in: app)
            tabs.buttons["Tasks"].tap()
            XCTAssertTrue(app.staticTexts["Tasks"].firstMatch.waitForExistence(timeout: 8))
            capture("Tasks", in: app)
            tabs.buttons["Settings"].tap()
            let limits = app.buttons["settings-safety"].firstMatch
            XCTAssertTrue(limits.waitForExistence(timeout: 8), app.debugDescription)
            capture("Settings", in: app)
            limits.tap()
            XCTAssertTrue(app.textFields["settings-limit-file"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        }
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
        let reveal = app.buttons["view-extraction-folder"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 12), app.debugDescription)
        reveal.tap()
        let note = app.buttons["workspace-file-notes.txt"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Extracted folder in Files"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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

    func testBrowseAndSelectAcrossFolders() {
        let app = XCUIApplication()
        app.launch()
        openFromFiles("MobileSample.zip", in: app)

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

    func testUnlockRAR5FromFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "1", "-conflictPolicy", "2"]
        app.launch()
        unlockFromFiles("MobileProtectedRAR.rar", previewing: "rar5-picker-note.txt", in: app,
                        checksWrongPassword: true)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["extract-all"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Extraction completed in Extracted Archives."]
            .waitForExistence(timeout: 10), app.debugDescription)
    }

    func testExtractSelectedEncryptedSolidRAR5FromFiles() {
        let app = XCUIApplication()
        app.launchArguments = ["-destinationPolicy", "1", "-conflictPolicy", "2"]
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
        XCTAssertTrue(app.staticTexts["Extraction completed in Extracted Archives."]
            .waitForExistence(timeout: 10), app.debugDescription)
    }

    private func checkUnlockFromFiles(_ name: String) {
        let app = XCUIApplication()
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

        let firstChild = app.buttons["open-nested-2"].firstMatch
        XCTAssertTrue(firstChild.waitForExistence(timeout: 10), app.debugDescription)
        firstChild.tap()
        let secondChild = app.buttons["open-nested-0"].firstMatch
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
            let folder = app.cells["AetherUnzip, Container"].firstMatch
            if folder.waitForExistence(timeout: 4) { folder.tap() }
        }
        XCTAssertTrue(fixtureCell.waitForExistence(timeout: 8), app.debugDescription)
        fixtureCell.tap()
        let accept = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "打开"])).firstMatch
        if accept.waitForExistence(timeout: 3) { accept.tap() }
    }
}
#endif
