import XCTest
@testable import NotchCapabilities

/// The extension → actions mapping is the whole feature: it decides what the
/// tray offers, and every argument it emits has to be one the CLI accepts
/// without stopping to prompt (a prompt in a GUI spawn is a hang). It is pure
/// string logic, so it is pinned here. Subprocess execution is deliberately not
/// tested — that needs the live CLI installed.
final class FileConversionServiceTests: XCTestCase {

    // MARK: - Helpers

    private func actions(_ ext: String) -> [FileConversionAction] {
        FileConversionCatalog.actions(forExtension: ext)
    }

    private func arguments(_ ext: String, tool: FileConversionAction.Tool) -> [String] {
        actions(ext).filter { $0.tool == tool }.map(\.argument)
    }

    // MARK: - Documents

    func testMarkdownOffersTheThreeDocumentTargets() {
        XCTAssertEqual(arguments("md", tool: .convert), ["docx", "pdf", "html"])
        // No image, background or compression story for a text file.
        XCTAssertEqual(actions("md").count, 3)
    }

    func testMarkdownAliasBehavesLikeMarkdown() {
        XCTAssertEqual(arguments("markdown", tool: .convert), ["docx", "pdf", "html"])
    }

    func testDocxAndHtml() {
        XCTAssertEqual(arguments("docx", tool: .convert), ["md", "pdf", "html"])
        XCTAssertEqual(arguments("html", tool: .convert), ["pdf", "md", "docx"])
    }

    // MARK: - Data

    func testCsvOffersTheDataTargets() {
        XCTAssertEqual(arguments("csv", tool: .convert), ["json", "yaml", "xlsx"])
    }

    func testJsonYamlAndXlsx() {
        XCTAssertEqual(arguments("json", tool: .convert), ["csv", "yaml", "xlsx"])
        XCTAssertEqual(arguments("yaml", tool: .convert), ["json", "csv", "xlsx"])
        XCTAssertEqual(arguments("xlsx", tool: .convert), ["csv", "json", "yaml"])
    }

    // MARK: - Images

    func testPngOffersConversionBackgroundRemovalAndCompression() {
        let png = actions("png")
        XCTAssertEqual(png.filter { $0.tool == .image }.map(\.argument), ["jpeg", "webp", "svg"])
        XCTAssertEqual(png.filter { $0.tool == .bg }.map(\.argument),
                       ["transparent", "white", "black"])
        XCTAssertEqual(png.filter { $0.tool == .compress }.map(\.argument),
                       ["normal", "super", "ultra"])
        // The convert tool knows nothing about raster images.
        XCTAssertTrue(png.filter { $0.tool == .convert }.isEmpty)
    }

    func testHeicIsConvertibleButNotCompressible() {
        let heic = actions("heic")
        XCTAssertEqual(heic.filter { $0.tool == .image }.map(\.argument),
                       ["png", "jpeg", "webp", "svg"])
        XCTAssertFalse(heic.filter { $0.tool == .bg }.isEmpty,
                       "Vision reads HEIC through ImageIO")
        XCTAssertTrue(heic.filter { $0.tool == .compress }.isEmpty,
                      "sharp cannot write HEIC back out, so compress does not accept it")
    }

    func testRawFilesGetImageConversionOnly() {
        let cr2 = actions("cr2")
        XCTAssertEqual(cr2.filter { $0.tool == .image }.map(\.argument),
                       ["png", "jpeg", "webp", "svg"])
        XCTAssertTrue(cr2.allSatisfy { $0.tool == .image })
    }

    // MARK: - Video and audio

    func testVideoOffersBothConvertAndCompress() {
        let mp4 = actions("mp4")
        XCTAssertEqual(mp4.filter { $0.tool == .convert }.map(\.argument), ["gif", "mp3"])
        XCTAssertEqual(mp4.filter { $0.tool == .compress }.map(\.argument),
                       ["normal", "super", "ultra"])
        XCTAssertFalse(mp4.filter { $0.tool == .convert }.isEmpty)
        XCTAssertFalse(mp4.filter { $0.tool == .compress }.isEmpty)
    }

    func testMovAlsoOffersRemuxToMp4() {
        let mov = actions("mov")
        XCTAssertEqual(mov.filter { $0.tool == .image }.map(\.argument), ["mp4"])
        XCTAssertEqual(mov.filter { $0.tool == .convert }.map(\.argument), ["gif", "mp3"])
        XCTAssertFalse(mov.filter { $0.tool == .compress }.isEmpty)
    }

    func testMp4IsNotOfferedRemuxingToItself() {
        XCTAssertTrue(actions("mp4").filter { $0.tool == .image }.isEmpty)
    }

    func testAudioOffersOnlyTranscoding() {
        XCTAssertEqual(arguments("wav", tool: .convert), ["mp3"])
        XCTAssertEqual(arguments("mp3", tool: .convert), ["wav"])
        XCTAssertEqual(arguments("flac", tool: .convert), ["mp3"])
        XCTAssertTrue(actions("mp3").allSatisfy { $0.tool == .convert },
                      "audio is neither compressible nor an image")
    }

    // MARK: - Case and dot tolerance

    func testUppercaseExtensionsBehaveTheSame() {
        XCTAssertEqual(actions("PNG"), actions("png"))
        XCTAssertEqual(actions("Mp4"), actions("mp4"))
        XCTAssertEqual(actions("MD"), actions("md"))
    }

    func testALeadingDotIsTolerated() {
        XCTAssertEqual(actions(".png"), actions("png"))
        XCTAssertEqual(actions(".csv"), actions("csv"))
    }

    func testActionsFromAURLUseItsExtension() {
        let url = URL(fileURLWithPath: "/tmp/Some Folder/Report.PDF.md")
        XCTAssertEqual(FileConversionCatalog.actions(for: url), actions("md"))
    }

    // MARK: - Nothing to offer

    func testUnknownExtensionsProduceNoActions() {
        XCTAssertTrue(actions("xyz").isEmpty)
        XCTAssertTrue(actions("").isEmpty)
        XCTAssertTrue(actions("app").isEmpty)
        XCTAssertTrue(actions("swift").isEmpty)
        // A folder or extensionless file arrives here as an empty string.
        XCTAssertTrue(FileConversionCatalog.actions(for: URL(fileURLWithPath: "/tmp/Notes")).isEmpty)
    }

    // MARK: - No self-conversion

    func testNoFormatIsOfferedAConversionToItself() {
        // Every source the catalog knows about, checked in one sweep: an action
        // that writes the extension the file already has is pure noise.
        let everything = FileConversionCatalog.imageSources
            .union(FileConversionCatalog.imageVideoSources)
            .union(FileConversionCatalog.backgroundSources)
            .union(FileConversionCatalog.compressImageSources)
            .union(FileConversionCatalog.compressVideoSources)
            .union(FileConversionCatalog.convertMatrix.keys)

        for source in everything {
            let selfFormat = FileConversionCatalog.normalized(source)
            // Only the two format-conversion tools. `compress` deliberately
            // writes the same container back, and `bg` always writes PNG —
            // "PNG in, PNG out" there is a cut-out, not a re-encode.
            for action in actions(source) where action.tool == .convert || action.tool == .image {
                XCTAssertNotEqual(
                    FileConversionCatalog.normalized(action.outputExtension ?? ""),
                    selfFormat,
                    "\(source) is offered a pointless conversion to \(action.argument)")
            }
        }
    }

    func testJpgAndJpegAreTheSameFormat() {
        XCTAssertFalse(arguments("jpg", tool: .image).contains("jpeg"))
        XCTAssertFalse(arguments("jpeg", tool: .image).contains("jpeg"))
        XCTAssertEqual(arguments("jpg", tool: .image), ["png", "webp", "svg"])
        // And jpg is never offered alongside jpeg — one encoder, one menu item.
        XCTAssertFalse(arguments("png", tool: .image).contains("jpg"))
    }

    func testHtmIsNotOfferedConversionToHtml() {
        XCTAssertFalse(arguments("htm", tool: .convert).contains("html"))
    }

    func testYmlIsNotOfferedConversionToYaml() {
        XCTAssertFalse(arguments("yml", tool: .convert).contains("yaml"))
    }

    // MARK: - Arguments the CLI would otherwise prompt for

    func testGifCarriesBothFrameRateAndWidth() {
        // The tool prompts unless it has *both* argv[4] and argv[5], and a
        // prompt with no TTY is a hang.
        let gif = actions("mp4").first { $0.argument == "gif" }
        XCTAssertEqual(gif?.extraArguments, ["15", "640"])
    }

    func testNonGifConversionsCarryNoExtraArguments() {
        XCTAssertEqual(actions("mp4").first { $0.argument == "mp3" }?.extraArguments, [])
        XCTAssertEqual(actions("md").first { $0.argument == "pdf" }?.extraArguments, [])
    }

    func testSvgAlwaysCarriesTheEmbedMode() {
        // The three tracing modes need vtracer on PATH; embed always works.
        let svg = actions("png").first { $0.argument == "svg" }
        XCTAssertEqual(svg?.extraArguments, ["embed"])
    }

    func testBackgroundRemovalCarriesTheSubjectMode() {
        for action in actions("png").filter({ $0.tool == .bg }) {
            XCTAssertEqual(action.extraArguments, ["all"],
                           "without argv[4] the tool stops and asks which subjects to keep")
        }
    }

    func testCustomBackgroundIsNeverOffered() {
        // `custom` alone triggers a hex-colour prompt, and the menu has nowhere
        // to ask for one.
        XCTAssertFalse(arguments("png", tool: .bg).contains("custom"))
    }

    func testTheArgumentVectorIsToolPathThenArguments() {
        let action = actions("md").first { $0.argument == "pdf" }!
        XCTAssertEqual(action.arguments(input: URL(fileURLWithPath: "/tmp/a b/notes.md")),
                       ["convert", "/tmp/a b/notes.md", "pdf"])

        let gif = actions("mp4").first { $0.argument == "gif" }!
        XCTAssertEqual(gif.arguments(input: URL(fileURLWithPath: "/tmp/clip.mp4")),
                       ["convert", "/tmp/clip.mp4", "gif", "15", "640"])
    }

    // MARK: - Output locations

    func testEachToolWritesIntoItsOwnFolderBesideTheInput() {
        XCTAssertEqual(FileConversionAction.Tool.convert.outputFolder, "converted")
        XCTAssertEqual(FileConversionAction.Tool.image.outputFolder, "converted")
        XCTAssertEqual(FileConversionAction.Tool.bg.outputFolder, "no-bg")
        XCTAssertEqual(FileConversionAction.Tool.compress.outputFolder, "compressed")
    }

    func testExpectedOutputPaths() {
        let md = URL(fileURLWithPath: "/tmp/convtest/a.md")
        let html = actions("md").first { $0.argument == "html" }!
        XCTAssertEqual(FileConversionCatalog.expectedOutputURL(for: html, input: md).path,
                       "/tmp/convtest/converted/a.html")

        let png = URL(fileURLWithPath: "/tmp/convtest/pic.png")
        let webp = actions("png").first { $0.argument == "webp" }!
        XCTAssertEqual(FileConversionCatalog.expectedOutputURL(for: webp, input: png).path,
                       "/tmp/convtest/converted/pic.webp")

        // The background is part of the name, so the variants never collide.
        let white = actions("png").first { $0.tool == .bg && $0.argument == "white" }!
        XCTAssertEqual(FileConversionCatalog.expectedOutputURL(for: white, input: png).path,
                       "/tmp/convtest/no-bg/pic-white.png")

        // Compression keeps the source container, so the mode is the only thing
        // distinguishing the output.
        let ultra = actions("png").first { $0.tool == .compress && $0.argument == "ultra" }!
        XCTAssertEqual(FileConversionCatalog.expectedOutputURL(for: ultra, input: png).path,
                       "/tmp/convtest/compressed/pic-ultra.png")

        let mp4 = URL(fileURLWithPath: "/tmp/convtest/clip.MP4")
        let normal = actions("mp4").first { $0.tool == .compress && $0.argument == "normal" }!
        XCTAssertEqual(FileConversionCatalog.expectedOutputURL(for: normal, input: mp4).path,
                       "/tmp/convtest/compressed/clip-normal.mp4",
                       "the CLI lowercases the extension it echoes back")
    }

    // MARK: - Menu grouping

    func testConvertAndImageShareOneMenuSection() {
        XCTAssertEqual(FileConversionAction.Tool.convert.sectionTitle,
                       FileConversionAction.Tool.image.sectionTitle)
        XCTAssertEqual(FileConversionAction.Tool.bg.sectionTitle, "Remove background")
        XCTAssertEqual(FileConversionAction.Tool.compress.sectionTitle, "Compress")
    }

    func testActionsAreOrderedConvertThenBackgroundThenCompress() {
        let tools = actions("jpg").map(\.tool)
        XCTAssertEqual(Array(Set(tools)).count, 3)
        XCTAssertEqual(tools.firstIndex(of: .image), 0)
        XCTAssertLessThan(tools.firstIndex(of: .bg)!, tools.firstIndex(of: .compress)!)
    }

    func testEveryActionHasADistinctIdentityAndALabel() {
        for source in ["png", "jpg", "mp4", "mov", "md", "csv", "heic"] {
            let list = actions(source)
            XCTAssertEqual(Set(list.map(\.id)).count, list.count,
                           "\(source) produced duplicate menu identities")
            XCTAssertTrue(list.allSatisfy { !$0.label.isEmpty })
        }
    }

    // MARK: - Transcript summarising

    func testTheFailureLineIsPulledOutOfTheBoxDrawing() {
        let transcript = """
        ┌  File Converter
        │
        ◇  Found ─────────╮
        │  1 document(s)  │
        ├─────────────────╯
        │
        └  ❌ Media conversion needs ffmpeg. Install it with: brew install ffmpeg
        """
        XCTAssertEqual(FileConversionService.summarize(transcript),
                       "Media conversion needs ffmpeg. Install it with: brew install ffmpeg")
    }

    func testTheSpinnersElapsedTimerIsNotPartOfTheMessage() {
        // Clack leaves its timer glued to whatever line the spinner stops on.
        XCTAssertEqual(
            FileConversionService.summarize("◇  ❌ Failed: bad.json -> .csv [0s]"),
            "Failed: bad.json -> .csv")
        XCTAssertEqual(
            FileConversionService.summarize("│\n└  ✅ clip.mp4 -> clip.gif [1m 12s]"),
            "✅ clip.mp4 -> clip.gif")
    }

    func testTheLastLineIsUsedWhenNothingIsMarkedAsAnError() {
        XCTAssertEqual(FileConversionService.summarize("│\n└  Nothing was compressed.\n"),
                       "Nothing was compressed.")
        XCTAssertNil(FileConversionService.summarize("   \n│\n└  \n"))
        XCTAssertNil(FileConversionService.summarize(""))
    }
}
