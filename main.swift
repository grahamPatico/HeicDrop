//
//  HeicDrop — menu bar image converter (HEIC/HEIF → JPEG, PNG, or HEIF)
//
//  Pure AppKit, single file, no Xcode project, no third-party deps.
//  Build with ./build.sh
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Preferences

/// Where a conversion goes. Not a mode — just the last destination used, preselected next time.
enum Destination: String {
    case folder
    case inPlaceDelete
    case clipboard
}

enum OutputFormat: String {
    case jpg
    case png
    case heif

    static let all: [OutputFormat] = [.jpg, .png, .heif]

    var utType: UTType {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .heif: return .heic
        }
    }

    var uti: CFString { utType.identifier as CFString }

    var fileExtension: String {
        switch self {
        case .jpg: return "jpg"
        case .png: return "png"
        case .heif: return "heic"
        }
    }

    var title: String {
        switch self {
        case .jpg: return "JPEG"
        case .png: return "PNG"
        case .heif: return "HEIF"
        }
    }

    /// PNG is lossless — passing a quality option to it is meaningless (and ImageIO logs about it).
    var usesQuality: Bool {
        switch self {
        case .jpg, .heif: return true
        case .png: return false
        }
    }
}

enum SizePreset: String {
    case actual
    case small
    case medium
    case large

    /// Max long-edge in pixels. `nil` means "leave the image alone". Numbers follow the
    /// Apple Mail convention for Small/Medium/Large.
    var maxPixels: Int? {
        switch self {
        case .actual: return nil
        case .small: return 320
        case .medium: return 640
        case .large: return 1280
        }
    }

    /// Title used as the leading word of a size row.
    var shortTitle: String {
        switch self {
        case .actual: return "Actual"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Size-row order — biggest first, which is what people scan for.
    static let askOrder: [SizePreset] = [.actual, .large, .medium, .small]

    /// Resulting pixel dimensions for an image of `size` (already orientation-corrected).
    /// Never upscales.
    func targetSize(for size: (w: Int, h: Int)) -> (w: Int, h: Int) {
        guard let m = maxPixels else { return size }
        let long = max(size.w, size.h)
        guard long > m, long > 0 else { return size }
        if size.w >= size.h {
            let h = Int((Double(size.h) * Double(m) / Double(size.w)).rounded())
            return (m, max(1, h))
        } else {
            let w = Int((Double(size.w) * Double(m) / Double(size.h)).rounded())
            return (max(1, w), m)
        }
    }
}

enum Prefs {
    static let destinationKey = "destination"
    static let outputFolderKey = "outputFolder"
    static let jpegQualityKey = "jpegQuality"
    static let outputFormatKey = "outputFormat"
    static let sizePresetKey = "sizePreset"
    static let stripMetadataKey = "stripMetadata"
    static let didAutoRegisterLoginKey = "didAutoRegisterLogin"

    static var destination: Destination {
        get {
            let raw = UserDefaults.standard.string(forKey: destinationKey) ?? Destination.folder.rawValue
            return Destination(rawValue: raw) ?? .folder
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: destinationKey) }
    }

    static var outputFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: outputFolderKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: outputFolderKey) }
    }

    static var jpegQuality: Double {
        get {
            let v = UserDefaults.standard.object(forKey: jpegQualityKey) as? Double
            guard let v, v > 0, v <= 1.0 else { return 0.9 }
            return v
        }
        set { UserDefaults.standard.set(newValue, forKey: jpegQualityKey) }
    }

    static var outputFormat: OutputFormat {
        get {
            let raw = UserDefaults.standard.string(forKey: outputFormatKey) ?? OutputFormat.jpg.rawValue
            return OutputFormat(rawValue: raw) ?? .jpg
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: outputFormatKey) }
    }

    static var sizePreset: SizePreset {
        get {
            let raw = UserDefaults.standard.string(forKey: sizePresetKey) ?? SizePreset.actual.rawValue
            return SizePreset(rawValue: raw) ?? .actual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sizePresetKey) }
    }

    static var stripMetadata: Bool {
        get { UserDefaults.standard.bool(forKey: stripMetadataKey) }
        set { UserDefaults.standard.set(newValue, forKey: stripMetadataKey) }
    }

    /// Set the first time the GUI launches, whether or not the register() call worked.
    /// A later manual uncheck must never be overridden by a second auto-register.
    static var didAutoRegisterLogin: Bool {
        get { UserDefaults.standard.bool(forKey: didAutoRegisterLoginKey) }
        set { UserDefaults.standard.set(newValue, forKey: didAutoRegisterLoginKey) }
    }
}

// MARK: - Login item

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    static func enable() throws { try SMAppService.mainApp.register() }

    static func disable() throws { try SMAppService.mainApp.unregister() }

    static func logError(_ error: Error, action: String) {
        FileHandle.standardError.write(Data("HeicDrop: \(action) login item failed: \(error)\n".utf8))
    }
}

// MARK: - Conversion (shared by GUI and CLI test mode)

enum ConvertError: Error, CustomStringConvertible {
    case cannotOpen(URL)
    case noImages(URL)
    case cannotCreateDestination(URL)
    case writeFailed(URL)
    case encodeFailed(URL)

    var description: String {
        switch self {
        case .cannotOpen(let u): return "cannot open image: \(u.path)"
        case .noImages(let u): return "no images found in: \(u.path)"
        case .cannotCreateDestination(let u): return "cannot create image destination: \(u.path)"
        case .writeFailed(let u): return "failed writing image: \(u.path)"
        case .encodeFailed(let u): return "failed encoding image from: \(u.path)"
        }
    }
}

enum Converter {
    static func makeSource(_ url: URL) throws -> CGImageSource {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            throw ConvertError.cannotOpen(url)
        }
        guard CGImageSourceGetCount(src) > 0 else { throw ConvertError.noImages(url) }
        return src
    }

    /// True if ImageIO can read this file at all.
    static func isReadableImage(_ url: URL) -> Bool {
        (try? makeSource(url)) != nil
    }

    /// Stored pixel dimensions with the EXIF orientation applied (orientations 5-8 swap w/h).
    static func orientedPixelSize(of url: URL) -> (w: Int, h: Int)? {
        guard let src = try? makeSource(url) else { return nil }
        return orientedPixelSize(of: src)
    }

    static func orientedPixelSize(of src: CGImageSource) -> (w: Int, h: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return orientedPixelSize(fromProperties: props)
    }

    private static func orientedPixelSize(fromProperties props: [CFString: Any]) -> (w: Int, h: Int)? {
        guard let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        return (orientation >= 5 && orientation <= 8) ? (h, w) : (w, h)
    }

    private static func qualityOptions(quality: Double, format: OutputFormat) -> [CFString: Any] {
        guard format.usesQuality else { return [:] }
        let clamped = min(max(quality, 0.0), 1.0)
        return [kCGImageDestinationLossyCompressionQuality: clamped]
    }

    /// The one shared encode path. Adds image index 0 of `src` to `dest`, resizing and/or
    /// stripping metadata as asked.
    private static func addImage(from src: CGImageSource,
                                 origin: URL,
                                 to dest: CGImageDestination,
                                 quality: Double,
                                 format: OutputFormat,
                                 maxPixels: Int?,
                                 stripMetadata: Bool) throws {
        let qualityOpts = qualityOptions(quality: quality, format: format)

        // Fast path: no resize, no strip. Passing source→destination directly keeps the
        // metadata and the orientation tag exactly as they were.
        if maxPixels == nil && !stripMetadata {
            CGImageDestinationAddImageFromSource(dest, src, 0, qualityOpts as CFDictionary)
            return
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        guard let stored = orientedPixelSize(fromProperties: props) else {
            throw ConvertError.encodeFailed(origin)
        }
        let longEdge = max(stored.w, stored.h)
        // Never upscale. When we are only stripping (no resize), asking for the image's own
        // long edge decodes it full-size while still applying the orientation transform.
        var thumbMax = longEdge
        if let m = maxPixels, m < longEdge { thumbMax = m }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbMax,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            throw ConvertError.encodeFailed(origin)
        }

        var destProps: [CFString: Any] = qualityOpts
        if !stripMetadata {
            var carried = props
            // The transform is already baked into the pixels, so the tag must read "up".
            carried[kCGImagePropertyOrientation] = 1
            if var tiff = carried[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                carried[kCGImagePropertyTIFFDictionary] = tiff
            }
            // These now describe the old size — let the encoder write the real ones.
            carried.removeValue(forKey: kCGImagePropertyPixelWidth)
            carried.removeValue(forKey: kCGImagePropertyPixelHeight)
            if var exif = carried[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                carried[kCGImagePropertyExifDictionary] = exif
            }
            for (key, value) in carried { destProps[key] = value }
        }

        CGImageDestinationAddImage(dest, image, destProps as CFDictionary)
    }

    /// Convert `source` to a file at `destination`.
    static func write(from source: URL,
                      to destination: URL,
                      quality: Double,
                      format: OutputFormat,
                      maxPixels: Int?,
                      stripMetadata: Bool) throws {
        let src = try makeSource(source)
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, format.uti, 1, nil
        ) else {
            throw ConvertError.cannotCreateDestination(destination)
        }
        try addImage(from: src, origin: source, to: dest, quality: quality,
                     format: format, maxPixels: maxPixels, stripMetadata: stripMetadata)
        guard CGImageDestinationFinalize(dest) else {
            throw ConvertError.writeFailed(destination)
        }
    }

    /// Convert `source` to in-memory data (clipboard path, and the popover size estimates).
    static func encode(source: URL,
                       quality: Double,
                       format: OutputFormat,
                       maxPixels: Int?,
                       stripMetadata: Bool) throws -> Data {
        let src = try makeSource(source)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, format.uti, 1, nil
        ) else {
            throw ConvertError.encodeFailed(source)
        }
        try addImage(from: src, origin: source, to: dest, quality: quality,
                     format: format, maxPixels: maxPixels, stripMetadata: stripMetadata)
        guard CGImageDestinationFinalize(dest) else {
            throw ConvertError.encodeFailed(source)
        }
        return data as Data
    }

    /// `<basename>.<ext>` in `folder`, appending " 2", " 3", ... on collision.
    static func uniqueDestination(for source: URL, in folder: URL, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

// MARK: - Headless CLI test mode

/// Returns an exit code if CLI mode was requested, otherwise nil (continue to GUI).
func runCLIIfRequested() -> Int32? {
    let args = Array(CommandLine.arguments.dropFirst())

    // Login-item flags. Headless, before NSApplication, same as --convert.
    if args.contains("--login-status") {
        print(LoginItem.statusName(LoginItem.status))
        return 0
    }
    if args.contains("--enable-login") {
        do {
            try LoginItem.enable()
            print(LoginItem.statusName(LoginItem.status))
            return 0
        } catch {
            LoginItem.logError(error, action: "registering")
            print(LoginItem.statusName(LoginItem.status))
            return 1
        }
    }
    if args.contains("--disable-login") {
        do {
            try LoginItem.disable()
            print(LoginItem.statusName(LoginItem.status))
            return 0
        } catch {
            LoginItem.logError(error, action: "unregistering")
            print(LoginItem.statusName(LoginItem.status))
            return 1
        }
    }

    guard let convertIdx = args.firstIndex(of: "--convert") else { return nil }

    guard convertIdx + 1 < args.count else {
        FileHandle.standardError.write(Data("error: --convert requires an input path\n".utf8))
        return 1
    }
    let input = URL(fileURLWithPath: args[convertIdx + 1])

    var outDir = Prefs.outputFolder
    if let outIdx = args.firstIndex(of: "--out") {
        guard outIdx + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --out requires a directory path\n".utf8))
            return 1
        }
        outDir = URL(fileURLWithPath: args[outIdx + 1], isDirectory: true)
    }

    var quality = Prefs.jpegQuality
    if let qIdx = args.firstIndex(of: "--quality"), qIdx + 1 < args.count,
       let q = Double(args[qIdx + 1]) {
        quality = q
    }

    var format = Prefs.outputFormat
    if let fIdx = args.firstIndex(of: "--format") {
        guard fIdx + 1 < args.count, let f = OutputFormat(rawValue: args[fIdx + 1].lowercased()) else {
            FileHandle.standardError.write(Data("error: --format requires jpg|png|heif\n".utf8))
            return 1
        }
        format = f
    }

    var size = Prefs.sizePreset
    if let sIdx = args.firstIndex(of: "--size") {
        guard sIdx + 1 < args.count, let s = SizePreset(rawValue: args[sIdx + 1].lowercased()) else {
            FileHandle.standardError.write(Data("error: --size requires actual|small|medium|large\n".utf8))
            return 1
        }
        size = s
    }

    let strip = args.contains("--strip") ? true : Prefs.stripMetadata

    do {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: outDir.path, isDirectory: &isDir) {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } else if !isDir.boolValue {
            FileHandle.standardError.write(Data("error: --out is not a directory: \(outDir.path)\n".utf8))
            return 1
        }
        let dest = Converter.uniqueDestination(for: input, in: outDir, ext: format.fileExtension)
        try Converter.write(from: input, to: dest, quality: quality, format: format,
                            maxPixels: size.maxPixels, stripMetadata: strip)
        print(dest.path)
        return 0
    } catch {
        let message: String
        if let ce = error as? ConvertError { message = ce.description } else { message = "\(error)" }
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }
}

// MARK: - Conversion results

struct BatchResult {
    var succeeded: [URL] = []
    var failed: [(URL, Error)] = []
    var anyFailure: Bool { !failed.isEmpty }
}

// MARK: - Drag destination view

final class DropView: NSView {
    weak var controller: AppController?

    init(frame: NSRect, controller: AppController) {
        self.controller = controller
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objs = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objs as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender)
        guard urls.contains(where: { Converter.isReadableImage($0) }) else {
            return []
        }
        controller?.setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.setHighlighted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.setHighlighted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.setHighlighted(false)
        let urls = fileURLs(from: sender).filter { Converter.isReadableImage($0) }
        guard !urls.isEmpty else { return false }
        controller?.handleDroppedFiles(urls)
        return true
    }

    // The drop view sits on top of the status item button, so it receives the click.
    override func mouseDown(with event: NSEvent) {
        controller?.leftClicked()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.rightClicked()
    }
}

// MARK: - Popover content

/// The whole UI. Two states, one controller: "files" (something pending) and "idle"
/// (no files — it doubles as the settings panel).
final class PopoverController: NSViewController {
    static let contentWidth: CGFloat = 320
    private static let padding: CGFloat = 14
    private static let innerWidth: CGFloat = contentWidth - 2 * padding

    weak var app: AppController?

    private(set) var files: [URL] = []

    // Live control references, rebuilt with the content.
    private var formatSegmented: NSSegmentedControl?
    private var sizeButtons: [NSButton] = []
    private var stripCheckbox: NSButton?
    private var destinationPopUp: NSPopUpButton?
    private var loginCheckbox: NSButton?

    // Working selections. Persisted immediately in idle state, on Convert in files state.
    private var selectedFormat: OutputFormat = .jpg
    private var selectedSize: SizePreset = .actual
    private var selectedStrip: Bool = false
    private var selectedDestinationIndex: Int = 0

    // Async byte estimates.
    private var estimateGeneration = 0
    private var byteTotals: [SizePreset: Int] = [:]
    private var firstDimensions: (w: Int, h: Int)?

    private static let chooseFolderIndex = 4

    init() { super.init(nibName: nil, bundle: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: PopoverController.contentWidth, height: 260))
        view = root
        // Installed once, not per rebuild, so repeated reloads cannot stack duplicates.
        // 999 so it yields silently to the popover's own sizing during the open animation.
        let width = root.widthAnchor.constraint(equalToConstant: PopoverController.contentWidth)
        width.priority = NSLayoutConstraint.Priority(999)
        width.isActive = true
    }

    // MARK: State

    private var isIdle: Bool { files.isEmpty }

    /// True when the size rows carry real per-file numbers.
    private var estimatesApply: Bool {
        !files.isEmpty && files.count <= AppController.byteEstimateFileLimit
    }

    /// Load the popover with `urls` ([] = idle) and rebuild the whole content.
    func configure(files urls: [URL]) {
        files = urls
        selectedFormat = Prefs.outputFormat
        selectedSize = Prefs.sizePreset
        selectedStrip = Prefs.stripMetadata
        selectedDestinationIndex = PopoverController.index(for: Prefs.destination)
        firstDimensions = estimatesApply ? urls.first.flatMap { Converter.orientedPixelSize(of: $0) } : nil
        byteTotals = [:]
        rebuild()
        recomputeEstimates()
    }

    private static func index(for destination: Destination) -> Int {
        switch destination {
        case .folder: return 0
        case .inPlaceDelete: return 1
        case .clipboard: return 2
        }
    }

    private static func destination(atIndex index: Int) -> Destination? {
        switch index {
        case 0: return .folder
        case 1: return .inPlaceDelete
        case 2: return .clipboard
        default: return nil
        }
    }

    // MARK: Build

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        formatSegmented = nil
        sizeButtons = []
        stripCheckbox = nil
        destinationPopUp = nil
        loginCheckbox = nil

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let pad = PopoverController.padding
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),
        ])

        stack.addArrangedSubview(isIdle ? buildIdleHeader() : buildFilesHeader())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(buildFormatSection())
        stack.addArrangedSubview(buildSizeSection())
        stack.addArrangedSubview(buildStripCheckbox())
        stack.addArrangedSubview(buildDestinationSection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(buildFooter())

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: PopoverController.contentWidth,
                                      height: view.fittingSize.height)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return box
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func pin(_ v: NSView, width: CGFloat = PopoverController.innerWidth) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    // MARK: Header — files state

    private func buildFilesHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let thumb = NSImageView()
        thumb.imageScaling = .scaleProportionallyDown
        thumb.image = files.first.flatMap { PopoverController.thumbnail(for: $0) }
        thumb.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 48),
            thumb.heightAnchor.constraint(equalToConstant: 48),
        ])

        let name = NSTextField(labelWithString: headerFilename())
        name.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let info = NSTextField(labelWithString: headerInfoLine())
        info.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        info.maximumNumberOfLines = 1
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [name, info])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        row.addArrangedSubview(thumb)
        row.addArrangedSubview(text)
        row.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return row
    }

    /// "IMG_1234.heic" or "IMG_1234.heic + 2 more".
    private func headerFilename() -> String {
        guard let first = files.first else { return "" }
        if files.count > 1 {
            return "\(first.lastPathComponent) + \(files.count - 1) more"
        }
        return first.lastPathComponent
    }

    /// "4032×3024 · HEIC · 3.2 MB" — first file's oriented dims, its extension, all files' bytes.
    private func headerInfoLine() -> String {
        var parts: [String] = []
        if let dims = files.first.flatMap({ Converter.orientedPixelSize(of: $0) }) {
            parts.append("\(dims.w)×\(dims.h)")
        }
        if let ext = files.first?.pathExtension, !ext.isEmpty {
            parts.append(ext.uppercased())
        }
        var total: Int64 = 0
        for url in files {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
        if total > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private static func thumbnail(for url: URL) -> NSImage? {
        guard let src = try? Converter.makeSource(url) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Header — idle state

    private func buildIdleHeader() -> NSView {
        let label = NSTextField(wrappingLabelWithString: "Drop images on the menu bar icon to convert")
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true

        let button = NSButton(title: "Choose Files…", target: self, action: #selector(chooseFilesClicked))

        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return stack
    }

    // MARK: Format

    private func buildFormatSection() -> NSView {
        let segmented = NSSegmentedControl(labels: OutputFormat.all.map { $0.title },
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(formatChanged(_:)))
        segmented.segmentDistribution = .fillEqually
        segmented.selectedSegment = OutputFormat.all.firstIndex(of: selectedFormat) ?? 0
        formatSegmented = segmented

        let stack = NSStackView(views: [sectionLabel("Format"), pin(segmented)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return stack
    }

    // MARK: Size

    private func buildSizeSection() -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3

        sizeButtons = []
        for preset in SizePreset.askOrder {
            let button = NSButton(radioButtonWithTitle: sizeRowTitle(preset),
                                  target: self,
                                  action: #selector(sizeChanged(_:)))
            button.tag = SizePreset.askOrder.firstIndex(of: preset) ?? 0
            button.state = (preset == selectedSize) ? .on : .off
            sizeButtons.append(button)
            column.addArrangedSubview(button)
        }

        let stack = NSStackView(views: [sectionLabel("Size"), column])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return stack
    }

    /// "Actual — 4032×3024 · 2.1 MB", or "…" for the byte figure while it is being computed,
    /// or "Large — max 1280 px" when there is nothing to measure.
    private func sizeRowTitle(_ preset: SizePreset) -> String {
        var parts: [String] = []
        if estimatesApply, let dims = firstDimensions {
            let target = preset.targetSize(for: dims)
            parts.append("\(target.w)×\(target.h)")
        } else if let max = preset.maxPixels {
            parts.append("max \(max) px")
        } else {
            parts.append("original size")
        }
        if estimatesApply {
            if let bytes = byteTotals[preset] {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            } else {
                parts.append("…")
            }
        }
        return "\(preset.shortTitle) — \(parts.joined(separator: " · "))"
    }

    private func updateSizeTitles() {
        for (index, button) in sizeButtons.enumerated() where index < SizePreset.askOrder.count {
            button.title = sizeRowTitle(SizePreset.askOrder[index])
        }
    }

    /// Encode every pending file at every preset with the CURRENT popover selections,
    /// on a background queue. A generation counter drops stale results.
    private func recomputeEstimates() {
        estimateGeneration += 1
        let generation = estimateGeneration
        byteTotals = [:]
        updateSizeTitles()

        guard estimatesApply else { return }

        let urls = files
        let format = selectedFormat
        let strip = selectedStrip
        let quality = Prefs.jpegQuality

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var totals: [SizePreset: Int] = [:]
            for preset in SizePreset.askOrder {
                var total = 0
                var ok = true
                for url in urls {
                    guard let data = try? Converter.encode(source: url,
                                                           quality: quality,
                                                           format: format,
                                                           maxPixels: preset.maxPixels,
                                                           stripMetadata: strip) else {
                        ok = false
                        break
                    }
                    total += data.count
                }
                if ok { totals[preset] = total }
            }
            DispatchQueue.main.async {
                guard let self, generation == self.estimateGeneration else { return }
                self.byteTotals = totals
                self.updateSizeTitles()
            }
        }
    }

    // MARK: Remove metadata

    private func buildStripCheckbox() -> NSView {
        let box = NSButton(checkboxWithTitle: "Remove metadata",
                           target: self,
                           action: #selector(stripChanged(_:)))
        box.state = selectedStrip ? .on : .off
        stripCheckbox = box
        return box
    }

    // MARK: Save to

    private func buildDestinationSection() -> NSView {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItem(withTitle: Prefs.outputFolder.lastPathComponent)
        popUp.addItem(withTitle: "Same folder, delete original")
        popUp.addItem(withTitle: "Clipboard")
        popUp.menu?.addItem(.separator())
        popUp.addItem(withTitle: "Choose Folder…")
        popUp.target = self
        popUp.action = #selector(destinationChanged(_:))
        popUp.selectItem(at: selectedDestinationIndex)
        destinationPopUp = popUp

        let stack = NSStackView(views: [sectionLabel("Save to"), pin(popUp)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return stack
    }

    // MARK: Footer

    private func buildFooter() -> NSView {
        let login = NSButton(checkboxWithTitle: "Start at Login",
                             target: self,
                             action: #selector(loginChanged(_:)))
        login.state = LoginItem.isEnabled ? .on : .off
        loginCheckbox = login

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true

        var views: [NSView] = [login, spacer]
        if isIdle {
            views.append(NSButton(title: "Quit", target: self, action: #selector(quitClicked)))
        } else {
            views.append(NSButton(title: "Cancel", target: self, action: #selector(cancelClicked)))
            let convert = NSButton(title: "Convert", target: self, action: #selector(convertClicked))
            convert.keyEquivalent = "\r"
            views.append(convert)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: PopoverController.innerWidth).isActive = true
        return row
    }

    // MARK: Actions

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < OutputFormat.all.count else { return }
        selectedFormat = OutputFormat.all[index]
        if isIdle { Prefs.outputFormat = selectedFormat }
        recomputeEstimates()
    }

    @objc private func sizeChanged(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < SizePreset.askOrder.count else { return }
        selectedSize = SizePreset.askOrder[sender.tag]
        for button in sizeButtons { button.state = (button === sender) ? .on : .off }
        if isIdle { Prefs.sizePreset = selectedSize }
    }

    @objc private func stripChanged(_ sender: NSButton) {
        selectedStrip = (sender.state == .on)
        if isIdle { Prefs.stripMetadata = selectedStrip }
        recomputeEstimates()
    }

    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index == PopoverController.chooseFolderIndex {
            chooseOutputFolder()
            return
        }
        guard let destination = PopoverController.destination(atIndex: index) else {
            sender.selectItem(at: selectedDestinationIndex)
            return
        }
        selectedDestinationIndex = index
        if isIdle { Prefs.destination = destination }
    }

    private func chooseOutputFolder() {
        // Pin the popover open for the duration of the modal panel; a .transient popover
        // would otherwise close the moment the panel takes over.
        app?.withPopoverPinned { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose the folder for converted images"
            panel.directoryURL = Prefs.outputFolder
            if panel.runModal() == .OK, let url = panel.url {
                Prefs.outputFolder = url
                self.destinationPopUp?.item(at: 0)?.title = url.lastPathComponent
                self.destinationPopUp?.selectItem(at: 0)
                self.selectedDestinationIndex = 0
                if self.isIdle { Prefs.destination = .folder }
            } else {
                self.destinationPopUp?.selectItem(at: self.selectedDestinationIndex)
            }
        }
    }

    @objc private func chooseFilesClicked() {
        var picked: [URL] = []
        app?.withPopoverPinned {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.image, .heic, .heif]
            panel.prompt = "Convert"
            panel.message = "Choose images to convert"
            guard panel.runModal() == .OK else { return }
            picked = panel.urls.filter { Converter.isReadableImage($0) }
        }
        guard !picked.isEmpty else { return }
        app?.showPopover(files: picked)
    }

    @objc private func loginChanged(_ sender: NSButton) {
        let wantEnabled = (sender.state == .on)
        do {
            if wantEnabled { try LoginItem.enable() } else { try LoginItem.disable() }
        } catch {
            LoginItem.logError(error, action: wantEnabled ? "registering" : "unregistering")
        }
        // Reflect what actually happened, not what was asked for.
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func cancelClicked() {
        // Discards every selection made in this session of the popover.
        app?.closePopover()
    }

    @objc private func convertClicked() {
        let urls = files
        guard !urls.isEmpty else { return }
        let destination = PopoverController.destination(atIndex: selectedDestinationIndex) ?? .folder

        Prefs.outputFormat = selectedFormat
        Prefs.sizePreset = selectedSize
        Prefs.stripMetadata = selectedStrip
        Prefs.destination = destination

        app?.startConversion(urls: urls, destination: destination, size: selectedSize)
    }
}

// MARK: - Controller

final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var dropView: DropView?
    private var pendingURLs: [URL] = []

    private let popover = NSPopover()
    private var popoverController: PopoverController?
    private var conversionStarted = false
    private var lastPopoverCloseTime: Date?

    /// Above this many files the popover stops encoding for byte estimates.
    static let byteEstimateFileLimit = 5

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildPopover()
        autoRegisterLoginItemIfNeeded()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // No statusItem.menu — a permanent menu would swallow drags.
        statusItem.menu = nil

        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "photo.badge.arrow.down",
                            accessibilityDescription: "HeicDrop")
            ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "HeicDrop")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "HeicDrop — drop images here to convert them"

        // Clicks arrive through DropView, which sits on top of the button. Wiring the
        // button's own target/action too would fire the same handler twice.
        let view = DropView(frame: button.bounds, controller: self)
        view.autoresizingMask = [.width, .height]
        button.addSubview(view)
        dropView = view
    }

    private func buildPopover() {
        let controller = PopoverController()
        controller.app = self
        popoverController = controller
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
    }

    /// First GUI launch registers the login item once. The flag is set whatever happens,
    /// so a later manual uncheck is never overridden.
    private func autoRegisterLoginItemIfNeeded() {
        guard !Prefs.didAutoRegisterLogin else { return }
        Prefs.didAutoRegisterLogin = true
        do {
            try LoginItem.enable()
        } catch {
            LoginItem.logError(error, action: "auto-registering")
        }
    }

    func setHighlighted(_ on: Bool) {
        statusItem?.button?.highlight(on)
    }

    // MARK: Click handling

    func leftClicked() {
        if popover.isShown {
            closePopover()
            return
        }
        // A transient popover closes itself on the click that lands on the status item,
        // so an immediate re-show here would defeat click-to-dismiss.
        if let closed = lastPopoverCloseTime, Date().timeIntervalSince(closed) < 0.25 { return }
        showPopover(files: [])
    }

    func rightClicked() {
        closePopover()
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let qualityItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let qualityMenu = NSMenu()
        let q = Prefs.jpegQuality
        for value in [0.8, 0.9, 1.0] {
            let item = NSMenuItem(title: "\(Int(value * 100))%",
                                  action: #selector(selectQuality(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = (abs(q - value) < 0.001) ? .on : .off
            qualityMenu.addItem(item)
        }
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit HeicDrop", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    @objc private func selectQuality(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Prefs.jpegQuality = value
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Popover plumbing

    func showPopover(files urls: [URL]) {
        guard let button = statusItem?.button else { return }
        pendingURLs = urls

        let controller: PopoverController
        if let existing = popoverController {
            controller = existing
        } else {
            controller = PopoverController()
            controller.app = self
            popoverController = controller
            popover.contentViewController = controller
        }

        controller.configure(files: urls)
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Keeps the popover open across a modal panel, then restores `.transient`.
    func withPopoverPinned(_ body: () -> Void) {
        let previous = popover.behavior
        popover.behavior = .applicationDefined
        NSApp.activate(ignoringOtherApps: true)
        body()
        popover.behavior = previous
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseTime = Date()
        // Click-away / Cancel must not leave stale files behind. A Convert already took
        // its own copy of the list.
        if !conversionStarted { pendingURLs = [] }
        conversionStarted = false
    }

    // MARK: Drop handling

    func handleDroppedFiles(_ urls: [URL]) {
        // Deferred: showing the popover inside performDragOperation would freeze the
        // Finder drop animation.
        DispatchQueue.main.async { [weak self] in
            self?.showPopover(files: urls)
        }
    }

    // MARK: Running a conversion

    func startConversion(urls: [URL], destination: Destination, size: SizePreset) {
        guard !urls.isEmpty else { return }
        conversionStarted = true
        pendingURLs = []
        closePopover()

        // Big batches must not sit on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: BatchResult
            switch destination {
            case .folder: result = self.saveToFolder(urls, sizeOverride: size)
            case .inPlaceDelete: result = self.saveInPlaceAndTrash(urls, sizeOverride: size)
            case .clipboard: result = self.copyToClipboard(urls, sizeOverride: size)
            }
            DispatchQueue.main.async { self.finish(result) }
        }
    }

    /// Runs `body` on the main thread, whichever thread we are on.
    private static func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
    }

    // MARK: The three actions

    private func saveToFolder(_ urls: [URL], sizeOverride: SizePreset? = nil) -> BatchResult {
        var result = BatchResult()
        let folder = Prefs.outputFolder
        let quality = Prefs.jpegQuality
        let format = Prefs.outputFormat
        let maxPixels = (sizeOverride ?? Prefs.sizePreset).maxPixels
        let strip = Prefs.stripMetadata
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            for url in urls { result.failed.append((url, error)) }
            return result
        }
        for url in urls {
            do {
                let dest = Converter.uniqueDestination(for: url, in: folder, ext: format.fileExtension)
                try Converter.write(from: url, to: dest, quality: quality, format: format,
                                    maxPixels: maxPixels, stripMetadata: strip)
                result.succeeded.append(dest)
            } catch {
                result.failed.append((url, error))
            }
        }
        return result
    }

    private func saveInPlaceAndTrash(_ urls: [URL], sizeOverride: SizePreset? = nil) -> BatchResult {
        var result = BatchResult()
        let quality = Prefs.jpegQuality
        let format = Prefs.outputFormat
        let maxPixels = (sizeOverride ?? Prefs.sizePreset).maxPixels
        let strip = Prefs.stripMetadata
        for url in urls {
            let folder = url.deletingLastPathComponent()
            do {
                let dest = Converter.uniqueDestination(for: url, in: folder, ext: format.fileExtension)
                try Converter.write(from: url, to: dest, quality: quality, format: format,
                                    maxPixels: maxPixels, stripMetadata: strip)
                // Only trash the original once the output is safely on disk.
                // Never removeItem — always Trash, so the user can undo.
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                result.succeeded.append(dest)
            } catch {
                result.failed.append((url, error))
            }
        }
        return result
    }

    private func copyToClipboard(_ urls: [URL], sizeOverride: SizePreset? = nil) -> BatchResult {
        var result = BatchResult()
        guard let first = urls.first else { return result }
        let quality = Prefs.jpegQuality
        let format = Prefs.outputFormat
        let maxPixels = (sizeOverride ?? Prefs.sizePreset).maxPixels
        let strip = Prefs.stripMetadata
        do {
            let data = try Converter.encode(source: first, quality: quality, format: format,
                                            maxPixels: maxPixels, stripMetadata: strip)
            // NSPasteboard is main-thread work; the encode above is not.
            AppController.onMain {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(data, forType: NSPasteboard.PasteboardType(format.utType.identifier))
                // Also write TIFF — many apps only accept TIFF from the pasteboard.
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
            result.succeeded.append(first)
        } catch {
            result.failed.append((first, error))
        }
        // Files beyond the first are ignored for the clipboard action (documented in README).
        return result
    }

    // MARK: Completion feedback

    private func finish(_ result: BatchResult) {
        // No UNUserNotification — permission prompts are a mess for unsigned apps.
        if result.anyFailure {
            NSSound(named: "Basso")?.play()
        } else if !result.succeeded.isEmpty {
            NSSound(named: "Glass")?.play()
        }
    }
}

// MARK: - Entry point

if let code = runCLIIfRequested() {
    exit(code)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
