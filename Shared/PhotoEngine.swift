import AVFoundation
import CryptoKit
import Observation
import Photos
import SwiftUI
import Vision

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
extension PlatformImage { var cg: CGImage? { cgImage } }
extension Image { init(platform: PlatformImage) { self.init(uiImage: platform) } }
#else
import AppKit
typealias PlatformImage = NSImage
extension PlatformImage { var cg: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) } }
extension Image { init(platform: PlatformImage) { self.init(nsImage: platform) } }
#endif

// MARK: - What Aerilo looks for

enum PhotoKind: String, CaseIterable, Identifiable, Sendable {
    case duplicates, similar, screenshots, whatsapp, recordings, videos

    var id: String { rawValue }
    var title: String {
        switch self {
        case .duplicates: return "Exact duplicates"
        case .similar: return "Similar shots"
        case .screenshots: return "Old screenshots"
        case .whatsapp: return "From WhatsApp"
        case .recordings: return "Screen recordings"
        case .videos: return "Largest videos"
        }
    }
    var icon: String {
        switch self {
        case .duplicates: return "square.on.square"
        case .similar: return "square.stack.3d.down.right"
        case .screenshots: return "camera.viewfinder"
        case .whatsapp: return "bubble.left.and.bubble.right"
        case .recordings: return "record.circle"
        case .videos: return "video"
        }
    }
    var note: String {
        switch self {
        case .duplicates: return "The same picture or video saved more than once. Aerilo keeps one of each, and never ticks a favourite."
        case .similar: return "Taken seconds apart and nearly the same. Aerilo suggests keeping one of each: a favourite if there is one, otherwise the first."
        case .screenshots: return "Screenshots older than 30 days. Favourites are not ticked."
        case .whatsapp: return "Pictures and videos WhatsApp saved to your library. Nothing is ticked: these are your conversations."
        case .recordings: return "Recordings of your screen. Nothing is ticked here."
        case .videos: return "Nothing is ticked here. Choose the ones you no longer need."
        }
    }
    /// Only clear leftovers are pre-selected. Videos, recordings and anything from a conversation
    /// are personal, and the hardest things to get back.
    var preselects: Bool { self == .duplicates || self == .similar || self == .screenshots }
}

struct PhotoItem: Identifiable, Hashable, Sendable {
    let id: String
    var bytes: Int64 = 0
    var date: Date?
    var isVideo = false
    var duration: TimeInterval = 0
    /// Marked as a favourite in Photos. Aerilo never ticks these itself.
    var isFavorite = false
    /// Drives the drawn sample picture in demo mode.
    var seed = 0
}

struct PhotoGroup: Identifiable, Sendable {
    let id: String
    let kind: PhotoKind
    var items: [PhotoItem]
    /// The one Aerilo suggests keeping, for duplicates and similar shots.
    var keepID: String?
}

// MARK: - Scanning

/// Reads the photo library and groups what could go. It never changes the library; deleting is a
/// separate step that the user starts and iOS confirms.
enum PhotoScanner {
    /// The picture's own data as stored on the device, or nil when it only lives in iCloud.
    /// Never downloads: a tidy-up should not pull the whole library onto the phone.
    static func imageData(of asset: PHAsset) -> Data? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.isNetworkAccessAllowed = false
        options.version = .current
        var found: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in found = data }
        return found
    }

    /// The name the picture or video was saved under, which is how apps such as WhatsApp mark theirs.
    static func filename(of asset: PHAsset) -> String {
        guard let resource = PHAssetResource.assetResources(for: asset).first else { return "" }
        if #available(iOS 27, macOS 27, tvOS 27, visionOS 27, *) { return resource.filename ?? "" }
        return resource.originalFilename
    }

    /// WhatsApp names what it saves "IMG-20260101-WA0007.jpg" or "WhatsApp Image 2026-01-01 at 10.00.00.jpeg".
    static func isFromWhatsApp(_ filename: String) -> Bool {
        if filename.hasPrefix("WhatsApp ") { return true }
        return filename.range(of: #"^[A-Z]{3}-\d{8}-WA\d+"#, options: .regularExpression) != nil
    }

    /// Bytes this asset takes on the device: the stored picture, or the video file.
    static func bytes(of asset: PHAsset) -> Int64 {
        // The system reports sizes directly from version 27 on, which is instant.
        if #available(iOS 27, macOS 27, tvOS 27, visionOS 27, *) {
            let sizes = PHAssetResource.assetResources(for: asset).compactMap(\.dataSize)
            if !sizes.isEmpty { return Int64(sizes.reduce(0, +)) }
        }
        guard asset.mediaType == .video else { return Int64(imageData(of: asset)?.count ?? 0) }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        let done = DispatchSemaphore(value: 0)
        var size: Int64 = 0
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
            if let url = (video as? AVURLAsset)?.url, let n = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { size = Int64(n) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 10)
        return size
    }

    /// Something that is equal only when two assets hold the same bytes: a SHA-256 of the stored picture or
    /// video. Nil when the bytes are not on the device, and then the asset is never called a duplicate.
    private static func fingerprint(of asset: PHAsset) -> String? {
        if asset.mediaType == .video { return contentHash(of: asset) }
        guard let data = imageData(of: asset) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a video's stored file, read in pieces so a long video never sits in memory.
    /// Never downloads from iCloud. Two different videos of the same length and size do not match.
    static func contentHash(of asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        // The edited video when there is one, since that is what the library shows; otherwise the original.
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo }) ?? resources.first(where: { $0.type == .video }) else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let done = DispatchSemaphore(value: 0)
        let hasher = Hasher256()
        let request = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { hasher.add($0) }, completionHandler: { error in
            if error != nil { hasher.fail() }
            done.signal()
        })
        // A video that cannot be read in ten minutes is simply not compared.
        guard done.wait(timeout: .now() + 600) == .success else {
            PHAssetResourceManager.default().cancelDataRequest(request)
            return nil
        }
        return hasher.result
    }

    /// Collects a hash across the pieces a video arrives in. The pieces come on another queue, hence the lock.
    private final class Hasher256: @unchecked Sendable {
        private var sha = SHA256()
        private var bytes = 0
        private var failed = false
        private let lock = NSLock()
        func add(_ data: Data) { lock.lock(); sha.update(data: data); bytes += data.count; lock.unlock() }
        func fail() { lock.lock(); failed = true; lock.unlock() }
        var result: String? {
            lock.lock(); defer { lock.unlock() }
            guard !failed, bytes > 0 else { return nil }
            return sha.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func item(_ asset: PHAsset, withSize: Bool = true) -> PhotoItem {
        PhotoItem(id: asset.localIdentifier, bytes: withSize ? bytes(of: asset) : 0, date: asset.creationDate,
                  isVideo: asset.mediaType == .video, duration: asset.duration, isFavorite: asset.isFavorite)
    }

    private static func best(of assets: [PHAsset]) -> PHAsset? {
        assets.first(where: \.isFavorite) ?? assets.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
    }

    /// What Aerilo remembers of a picture in order to compare it with the next one.
    struct Look {
        /// Apple's image feature print: good at "the same scene", but not available on every device.
        var print: VNFeaturePrintObservation?
        /// A 64-bit difference hash of a tiny grey copy: plain arithmetic, so it always works.
        var hash: UInt64?
    }

    static func look(at image: CGImage) -> Look {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return Look(print: request.results?.first, hash: differenceHash(image))
    }

    /// Shrinks the picture to 9 x 8 grey pixels and records, for each pixel, whether it is brighter
    /// than its right-hand neighbour. Near-identical pictures differ in only a few of the 64 bits.
    static func differenceHash(_ image: CGImage) -> UInt64? {
        var pixels = [UInt8](repeating: 0, count: 72)
        guard let context = CGContext(data: &pixels, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        var hash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 where pixels[row * 9 + column] > pixels[row * 9 + column + 1] {
                hash |= 1 << UInt64(row * 8 + column)
            }
        }
        return hash
    }

    /// True when two pictures taken moments apart look like the same shot.
    static func alike(_ a: Look, _ b: Look) -> Bool {
        if let pa = a.print, let pb = b.print {
            var distance: Float = .infinity
            // Measured on test pictures: the same shot a second later scores 0.03 to 0.04, different
            // pictures 0.23 and up. Erring towards "different" only means fewer suggestions.
            if (try? pa.computeDistance(&distance, to: pb)) != nil { return distance < 0.15 }
        }
        if let ha = a.hash, let hb = b.hash { return (ha ^ hb).nonzeroBitCount <= 8 }
        return false
    }

    private static func look(at asset: PHAsset) -> Look? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        // Not `.fastFormat`: that only answers when a cached thumbnail exists, and returns nothing otherwise.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false // never pull originals from iCloud just to compare
        var image: PlatformImage?
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 256, height: 256), contentMode: .aspectFit, options: options) { result, _ in
            image = result
        }
        return image?.cg.map { look(at: $0) }
    }

    static func scan(progress: @escaping @Sendable (String) -> Void) -> (groups: [PhotoGroup], total: Int) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        var groups: [PhotoGroup] = []
        var taken = Set<String>()

        // 1. Exact duplicates: same kind, size in pixels, second of capture and length, and then the very same bytes.
        progress("Looking for exact duplicates")
        var buckets: [String: [PHAsset]] = [:]
        for asset in assets {
            guard let date = asset.creationDate else { continue }
            let key = "\(asset.mediaType.rawValue)|\(asset.pixelWidth)x\(asset.pixelHeight)|\(Int(date.timeIntervalSince1970))|\(Int(asset.duration * 10))"
            buckets[key, default: []].append(asset)
        }
        for (key, bucket) in buckets where bucket.count > 1 {
            // Videos are hashed only when another video in the bucket has the same file size: reading a
            // whole video is slow, and two files of different sizes cannot be the same.
            var candidates = bucket
            if bucket[0].mediaType == .video {
                let sized = Dictionary(grouping: bucket) { bytes(of: $0) }
                candidates = sized.filter { $0.key > 0 && $0.value.count > 1 }.flatMap(\.value)
            }
            var same: [String: [PHAsset]] = [:]
            for asset in candidates {
                if let print = fingerprint(of: asset) { same[print, default: []].append(asset) }
            }
            for (print, copies) in same where copies.count > 1 {
                let keep = best(of: copies)
                groups.append(PhotoGroup(id: "dup-\(key)-\(print.prefix(12))", kind: .duplicates, items: copies.map { item($0) }, keepID: keep?.localIdentifier))
                copies.forEach { taken.insert($0.localIdentifier) }
            }
        }

        // 2. Similar shots: photos taken within five seconds of each other that also look alike.
        progress("Comparing shots taken moments apart")
        var chains: [[PHAsset]] = []
        var chain: [PHAsset] = []
        var compared = 0
        func close() {
            if chain.count > 1 { chains.append(chain) }
            chain = []
        }
        for asset in assets where asset.mediaType == .image && !asset.mediaSubtypes.contains(.photoScreenshot) && !taken.contains(asset.localIdentifier) {
            if let last = chain.last, let a = last.creationDate, let b = asset.creationDate,
               b.timeIntervalSince(a) <= 5, last.pixelWidth == asset.pixelWidth, last.pixelHeight == asset.pixelHeight {
                chain.append(asset)
            } else {
                close()
                chain = [asset]
            }
        }
        close()
        for candidates in chains {
            // Keep the comparison bounded on very large libraries.
            guard compared < 4000 else { break }
            compared += candidates.count
            var cluster: [PHAsset] = [candidates[0]]
            var previous = look(at: candidates[0])
            func flush() {
                if cluster.count > 1 {
                    let keep = best(of: cluster)
                    groups.append(PhotoGroup(id: "sim-\(cluster[0].localIdentifier)", kind: .similar, items: cluster.map { item($0) }, keepID: keep?.localIdentifier))
                    // One picture, one place: a tick is shared by id, so a picture listed twice would arrive
                    // ticked in a list that promises nothing is ticked, and be counted twice.
                    cluster.forEach { taken.insert($0.localIdentifier) }
                }
            }
            for asset in candidates.dropFirst() {
                let current = look(at: asset)
                if let previous, let current, alike(previous, current) {
                    cluster.append(asset)
                } else {
                    flush()
                    cluster = [asset]
                }
                previous = current
            }
            flush()
        }

        // 3. Screenshots older than 30 days.
        progress("Finding old screenshots")
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let shots = assets.filter { $0.mediaSubtypes.contains(.photoScreenshot) && ($0.creationDate ?? Date()) < cutoff && !taken.contains($0.localIdentifier) }
        if !shots.isEmpty {
            groups.append(PhotoGroup(id: "screenshots", kind: .screenshots, items: shots.map { item($0) }, keepID: nil))
            shots.forEach { taken.insert($0.localIdentifier) }
        }

        // 4. What WhatsApp saved: by its file names, and by the album it keeps.
        progress("Looking for pictures saved by WhatsApp")
        var whatsappIDs = Set<String>()
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        albums.enumerateObjects { album, _, _ in
            guard (album.localizedTitle ?? "").hasPrefix("WhatsApp") else { return }
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in whatsappIDs.insert(asset.localIdentifier) }
        }
        var named = 0
        let fromWhatsApp = assets.filter { asset in
            guard !taken.contains(asset.localIdentifier) else { return false }
            if whatsappIDs.contains(asset.localIdentifier) { return true }
            // Reading names is quick but not free; stop after the newest 20,000.
            named += 1
            return named <= 20_000 && isFromWhatsApp(filename(of: asset))
        }
        if !fromWhatsApp.isEmpty {
            groups.append(PhotoGroup(id: "whatsapp", kind: .whatsapp, items: fromWhatsApp.map { item($0) }.sorted { $0.bytes > $1.bytes }, keepID: nil))
            fromWhatsApp.forEach { taken.insert($0.localIdentifier) }
        }

        // 5. Screen recordings.
        let recordings = assets.filter { $0.mediaType == .video && $0.mediaSubtypes.contains(.videoScreenRecording) && !taken.contains($0.localIdentifier) }
        if !recordings.isEmpty {
            groups.append(PhotoGroup(id: "recordings", kind: .recordings, items: recordings.map { item($0) }.sorted { $0.bytes > $1.bytes }, keepID: nil))
            recordings.forEach { taken.insert($0.localIdentifier) }
        }

        // 6. The largest videos.
        progress("Measuring videos")
        let videos = assets.filter { $0.mediaType == .video && !taken.contains($0.localIdentifier) }
            .map { item($0) }
            .filter { $0.bytes >= 50 << 20 }
            .sorted { $0.bytes > $1.bytes }
            .prefix(30)
        if !videos.isEmpty {
            groups.append(PhotoGroup(id: "videos", kind: .videos, items: Array(videos), keepID: nil))
        }
        return (groups, assets.count)
    }
}

// MARK: - Model

@MainActor @Observable
final class PhotoModel {
    static let shared = PhotoModel()

    enum Access { case unknown, full, limited, denied }

    var phase: BreathPhase = .idle
    var phaseStart = Date()
    var steps: [String] = []
    var access: Access = .unknown
    var groups: [PhotoGroup] = []
    /// Ids ticked for deletion.
    var selected: Set<String> = []
    var assetCount = 0
    var lastFreed: Int64 = 0
    var lastDeleted = 0
    var deleting = false

    init() {
        if Env.isDemo { PhotoDemo.fill(self) }
    }

    func items(_ kind: PhotoKind) -> [PhotoItem] { groups.filter { $0.kind == kind }.flatMap(\.items) }
    func bytes(_ kind: PhotoKind) -> Int64 { items(kind).reduce(0) { $0 + $1.bytes } }
    func selectedItems(_ kind: PhotoKind) -> [PhotoItem] { items(kind).filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { groups.flatMap(\.items).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    var kindsFound: [PhotoKind] { PhotoKind.allCases.filter { !items($0).isEmpty } }

    /// One sentence from the on-device model, when the device has one. Nil falls back to `summary`.
    var advice: String?

    var headline: String { phase == .done ? (advice ?? summary) : "" }

    var summary: String {
        guard phase == .done else { return "" }
        if access == .denied { return "Aerilo can't see your photos yet." }
        if groups.isEmpty { return lastDeleted > 0 ? "Lighter by \(Fmt.bytes(lastFreed))." : "Your library is already tidy." }
        let suggested = selected.count
        return suggested > 0 ? "\(Fmt.items(suggested)) could go, freeing \(Fmt.bytes(selectedBytes))." : "Have a look at your largest videos."
    }

    func setPhase(_ p: BreathPhase) {
        phaseStart = Date()
        withAnimation(.easeInOut(duration: 1.2)) { phase = p }
    }

    private func note(_ text: String) { steps.append(text) }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Asks for the library, looks through it and groups what could go. Deletes nothing.
    func breathe() async {
        guard phase == .idle || phase == .done, !deleting else { return }
        if Env.isDemo { await PhotoDemo.breathe(self); return }
        steps = []
        setPhase(.inhale)
        let began = Date()

        note("Asking to see your photo library")
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = status == .authorized ? .full : status == .limited ? .limited : .denied
        Audit.record("photos.access", ["status": access == .full ? "allowed" : access == .limited ? "limited to chosen photos" : "not allowed"])
        if access == .denied {
            groups = []
            setPhase(.done)
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            PhotoScanner.scan { text in Task { @MainActor in PhotoModel.shared.steps.append(text) } }
        }.value
        groups = result.groups
        assetCount = result.total
        selected = Set(groups.filter { $0.kind.preselects }.flatMap { group in group.items.filter { $0.id != group.keepID && !$0.isFavorite }.map(\.id) })
        Audit.record("photos.scan", ["assets": assetCount, "found": selected.count, "bytes": selectedBytes])
        note("Thinking about what helps most")
        advice = await PhotoAdvisor.sentence(for: self)

        let left = 3.0 - Date().timeIntervalSince(began)
        if left > 0 { try? await Task.sleep(for: .seconds(left)) }
        note(groups.isEmpty ? "Nothing needs tidying" : "Ready for you to review")
        setPhase(.exhale)
        try? await Task.sleep(for: .seconds(3.2))
        setPhase(.done)
    }

    /// Everything of one kind that "Delete all" would remove: every item, except the one copy Aerilo
    /// suggests keeping in each group of duplicates or similar shots, so no picture loses its last copy.
    func allDeletable(_ kind: PhotoKind) -> [PhotoItem] {
        groups.filter { $0.kind == kind }.flatMap { group in group.items.filter { $0.id != group.keepID } }
    }

    /// Ticks everything of one kind (but the suggested keepers) and deletes it. The system still asks the
    /// user to confirm; if they decline, the ticks stay so they can see what was about to go.
    func deleteAll(in kind: PhotoKind) async {
        guard !deleting else { return }
        let keepers = Set(groups.filter { $0.kind == kind }.compactMap(\.keepID))
        selected.subtract(keepers)
        selected.formUnion(allDeletable(kind).map(\.id))
        await deleteSelected(in: kind)
    }

    /// Deletes the ticked items of one kind. The system asks the user to confirm, and the items
    /// stay in Recently Deleted for 30 days.
    func deleteSelected(in kind: PhotoKind) async {
        let targets = selectedItems(kind)
        guard !targets.isEmpty, !deleting else { return }
        deleting = true
        defer { deleting = false }
        let ids = targets.map(\.id)
        let bytes = targets.reduce(Int64(0)) { $0 + $1.bytes }
        if Env.isDemo { remove(ids, bytes: bytes); return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            Audit.record("photos.delete", ["count": ids.count, "bytes": bytes, "kinds": kind.title])
            remove(ids, bytes: bytes)
        } catch {
            Audit.record("photos.delete.cancelled", ["count": ids.count])
        }
    }

    private func remove(_ ids: [String], bytes: Int64) {
        let gone = Set(ids)
        selected.subtract(gone)
        groups = groups.compactMap { group in
            var g = group
            g.items.removeAll { gone.contains($0.id) }
            // A duplicate or similar group with one picture left has nothing more to offer.
            if g.items.isEmpty || (g.keepID != nil && g.items.count < 2) { return nil }
            return g
        }
        lastFreed += bytes
        lastDeleted += ids.count
        advice = nil // the numbers changed; show the plain count again
    }
}

// MARK: - Assistant

#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Apple's on-device model, where the device has it, turns the counts into one helpful sentence.
/// It only sees numbers and category names, never a photo, and it cannot delete anything.
enum PhotoAdvisor {
    static var isReady: Bool {
        #if canImport(FoundationModels) && !os(tvOS)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func facts(_ kinds: [(title: String, count: Int, bytes: Int64, suggested: Int)], total: Int) -> String {
        var lines = ["The library has \(total) photos and videos."]
        for k in kinds {
            lines.append("- \(k.title): \(k.count) items using \(Fmt.bytes(k.bytes)); \(k.suggested) suggested for deletion.")
        }
        // The model is small; naming the answer to "where is the most space" keeps it from guessing.
        // Wording here was chosen by trial: Apple's safety filter rejected other phrasings of the same request,
        // in which case `sentence` returns nil and the plain count is shown.
        if let biggest = kinds.max(by: { $0.bytes < $1.bytes }) {
            lines.append("The category using the most space is \(biggest.title) (\(Fmt.bytes(biggest.bytes))).")
        }
        return lines.joined(separator: "\n")
    }

    static func sentence(facts: String) async -> String? {
        #if canImport(FoundationModels) && !os(tvOS)
        guard isReady else { return nil }
        let instructions = "You are Aerilo, a calm assistant that helps tidy a photo library. Given the counts, say in one short, plain sentence (at most 18 words) where the person should start to free the most space. Use only the numbers given. Never say anything was deleted."
        let answer: String? = await Timeout.run(seconds: 10) {
            try? await LanguageModelSession(instructions: instructions).respond(to: facts).content
        }
        let text = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
        #else
        return nil
        #endif
    }

    @MainActor static func sentence(for model: PhotoModel) async -> String? {
        guard !model.groups.isEmpty else { return nil }
        let kinds = model.kindsFound.map { (title: $0.title, count: model.items($0).count, bytes: model.bytes($0), suggested: model.selectedItems($0).count) }
        return await sentence(facts: facts(kinds, total: model.assetCount))
    }
}

// MARK: - Sample data for screenshots

@MainActor
enum PhotoDemo {
    static func fill(_ m: PhotoModel) {
        let shot = Env.arg("--shot") ?? "home"
        guard shot != "home" else { return }
        load(m)
        m.phase = shot == "exhale" ? .exhale : .done
        if shot == "exhale" {
            m.phaseStart = Date().addingTimeInterval(1.2)
            m.steps = ["Looking for exact duplicates", "Comparing shots taken moments apart", "Measuring videos", "Ready for you to review"]
        }
    }

    static func load(_ m: PhotoModel) {
        var groups: [PhotoGroup] = []
        let mb: Int64 = 1_000_000
        var n = 0
        func items(_ count: Int, seed: Int, bytes: Int64, video: Bool = false, vary: Bool = false) -> [PhotoItem] {
            (0..<count).map { i in
                n += 1
                return PhotoItem(id: "demo-\(n)", bytes: bytes + Int64(i) * mb / 3, date: Date().addingTimeInterval(Double(-n) * 86_400),
                                 isVideo: video, duration: video ? Double(40 + i * 37) : 0, seed: vary ? seed + i : seed)
            }
        }
        for (i, count) in [2, 3, 2, 2, 2].enumerated() {
            let g = items(count, seed: 10 + i * 7, bytes: 4 * mb)
            groups.append(PhotoGroup(id: "dup\(i)", kind: .duplicates, items: g, keepID: g[0].id))
        }
        for (i, count) in [4, 3, 5, 3, 4, 3].enumerated() {
            let g = items(count, seed: 60 + i * 11, bytes: 5 * mb)
            groups.append(PhotoGroup(id: "sim\(i)", kind: .similar, items: g, keepID: g[1].id))
        }
        groups.append(PhotoGroup(id: "screenshots", kind: .screenshots, items: items(48, seed: 200, bytes: 2 * mb, vary: true), keepID: nil))
        groups.append(PhotoGroup(id: "whatsapp", kind: .whatsapp, items: items(64, seed: 400, bytes: 3 * mb / 2, vary: true), keepID: nil))
        var recorded = items(5, seed: 500, bytes: 0, video: true, vary: true)
        for (i, size) in [620, 310, 240, 95, 60].enumerated() { recorded[i].bytes = Int64(size) * mb }
        groups.append(PhotoGroup(id: "recordings", kind: .recordings, items: recorded, keepID: nil))
        var videos = items(12, seed: 300, bytes: 0, video: true, vary: true)
        for (i, size) in [4200, 3100, 2650, 1900, 1420, 1180, 960, 740, 610, 480, 350, 220].enumerated() { videos[i].bytes = Int64(size) * mb }
        groups.append(PhotoGroup(id: "videos", kind: .videos, items: videos, keepID: nil))
        m.groups = groups
        m.assetCount = 12_480
        m.access = .full
        m.selected = Set(groups.filter { $0.kind.preselects }.flatMap { group in group.items.map(\.id).filter { $0 != group.keepID } })
    }

    static func breathe(_ m: PhotoModel) async {
        m.steps = []
        m.setPhase(.inhale)
        for text in ["Looking for exact duplicates", "Comparing shots taken moments apart", "Looking for pictures saved by WhatsApp", "Measuring videos"] {
            m.steps.append(text)
            try? await Task.sleep(for: .seconds(0.8))
        }
        load(m)
        m.steps.append("Ready for you to review")
        m.setPhase(.exhale)
        try? await Task.sleep(for: .seconds(3.2))
        m.setPhase(.done)
    }
}
