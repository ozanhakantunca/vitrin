import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import os

internal enum ThumbnailMath {
    static func fit(source: CGSize, into limit: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite, limit.width.isFinite, limit.height.isFinite,
              source.width > 0, source.height > 0, limit.width > 0, limit.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let scale = min(1, limit.width / source.width, limit.height / source.height)
        return CGSize(width: max(1, floor(source.width * scale)), height: max(1, floor(source.height * scale)))
    }
}

internal struct ThumbnailLRU<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    init(capacity: Int) { self.capacity = max(0, capacity) }
    mutating func get(_ key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return value
    }
    mutating func set(_ key: Key, _ value: Value) {
        order.removeAll { $0 == key }; values[key] = value; order.append(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }
    mutating func remove(_ key: Key) { values.removeValue(forKey: key); order.removeAll { $0 == key } }
    mutating func removeAll() { values.removeAll(); order.removeAll() }
}

public final class ThumbnailProvider: ThumbnailProviding, @unchecked Sendable {
    private struct State {
        var cache = ThumbnailLRU<CGWindowID, (CGImage, Date)>(capacity: 200)
        var pending: [CGWindowID: Task<CGImage?, Never>] = [:]
        var content: SCShareableContent?
        var contentDate = Date.distantPast
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public var isAvailable: Bool { CGPreflightScreenCaptureAccess() }
    public func cachedThumbnail(for windowID: CGWindowID) -> CGImage? {
        guard isAvailable else { return nil }
        return state.withLock { $0.cache.get(windowID)?.0 }
    }
    public func invalidate(windowID: CGWindowID) { state.withLock { $0.cache.remove(windowID) } }
    public func removeAll() { state.withLock { $0.cache.removeAll() } }
    public func thumbnail(for windowID: CGWindowID, maxPixelSize: CGSize) async -> CGImage? {
        guard isAvailable else { return nil }
        let task = state.withLock { state -> Task<CGImage?, Never> in
            if let task = state.pending[windowID] { return task }
            let task = Task { [self] in await capture(windowID, maxPixelSize) }
            state.pending[windowID] = task
            return task
        }
        return await task.value
    }
    private func capture(_ id: CGWindowID, _ size: CGSize) async -> CGImage? {
        defer { _ = state.withLock { $0.pending.removeValue(forKey: id) } }
        do {
            var content = state.withLock { state in
                Date().timeIntervalSince(state.contentDate) < 2 ? state.content : nil
            }
            if content == nil || !(content?.windows.contains { $0.windowID == id } ?? false) {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let content { state.withLock { $0.content = content; $0.contentDate = Date() } }
            }
            guard let window = content?.windows.first(where: { $0.windowID == id }) else {
                return state.withLock { $0.cache.get(id)?.0 }
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let fitted = ThumbnailMath.fit(source: window.frame.size, into: size)
            config.width = Int(fitted.width); config.height = Int(fitted.height)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            if #available(macOS 14.0, *) { config.ignoreShadowsSingleWindow = true; config.shouldBeOpaque = true }
            let image: CGImage?
            if #available(macOS 14.0, *) {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } else {
                image = await OneFrame.capture(filter: filter, configuration: config)
            }
            if let image { state.withLock { $0.cache.set(id, (image, Date())) }; return image }
        } catch { }
        return state.withLock { $0.cache.get(id)?.0 }
    }
}

private final class OneFrame: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private func finish(_ image: CGImage?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: image)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        finish(image)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { finish(nil) }
    static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration) async -> CGImage? {
        let output = OneFrame()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "vitrin.thumbnail.frame"))
            let image = await withCheckedContinuation { continuation in
                output.lock.lock(); output.continuation = continuation; output.lock.unlock()
                Task { do { try await stream.startCapture() } catch { output.finish(nil) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { output.finish(nil) }
            }
            try? await stream.stopCapture()
            return image
        } catch { return nil }
    }
}
