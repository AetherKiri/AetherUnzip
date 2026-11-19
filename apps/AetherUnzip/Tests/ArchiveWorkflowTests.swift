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
    func testOpenWithFormatProfileFromFiles() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["open-archive"].firstMatch.waitForExistence(timeout: 10))
        let profileAction = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "open-format-profile", "Open with Format Profile…")).firstMatch
        if !profileAction.exists || !profileAction.isHittable {
            let more = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@",
                ["More", "更多", "More Actions"])).firstMatch
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
        XCTAssertTrue(open.waitForExistence(timeout: 10))
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
