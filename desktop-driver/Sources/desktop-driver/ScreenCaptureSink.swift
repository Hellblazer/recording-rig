// SPDX-License-Identifier: MIT
//
// Live CaptureSink implementation (RDR-001 §Technical Design L246). Captures the
// Claude-Rig window's compositor output via ScreenCaptureKit and writes an h264
// .mov via AVAssetWriter. Validated in Phase 0 (T2 recording-rig/
// claude-app-screencapturekit-recording-viable). Compile-verified only; runtime
// behavior is gated by rr-2pp.3.6.

import AVFoundation
import CoreMedia
import CoreVideo
import DesktopDriverCore
import Foundation
import ScreenCaptureKit

final class ScreenCaptureSink: NSObject, CaptureSink, SCStreamOutput {
    private let rigPid: pid_t
    private let outputURL: URL
    private let sampleQueue = DispatchQueue(label: "recording-rig.capture.samples")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false

    init(rigPid: pid_t, outputPath: String) {
        self.rigPid = rigPid
        self.outputURL = URL(fileURLWithPath: outputPath)
        super.init()
    }

    func start() throws {
        let content = try shareableContent()
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == rigPid && $0.isOnScreen
        }) else {
            throw DriverError.badConfig("no on-screen window for Claude-Rig pid \(rigPid)")
        }

        // Capture the window's full compositor output (all layers, incl. any
        // BrowserView/GPU content) — supersedes the old page.screencast concern.
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // 2x backing scale (Apple Silicon Retina default). The exact per-display
        // factor is verified against the live window at the rr-2pp.3.6 gate.
        let retinaScale = 2
        let pixelWidth = Int(window.frame.width.rounded()) * retinaScale
        let pixelHeight = Int(window.frame.height.rounded()) * retinaScale

        let config = SCStreamConfiguration()
        config.width = max(2, pixelWidth)
        config.height = max(2, pixelHeight)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw DriverError.badConfig("AVAssetWriter cannot add video input")
        }
        writer.add(input)
        self.writer = writer
        self.videoInput = input

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream

        try awaitCompletion("startCapture") { stream.startCapture(completionHandler: $0) }
    }

    // SCStreamOutput: append complete frames; start the writer session on the
    // first frame's PTS (RDR — "start the writer session on the first frame's PTS").
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer),
              let writer = self.writer, let input = self.videoInput else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else {
            return
        }

        if !sessionStarted {
            guard writer.status == .unknown else { return }
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }

        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish() throws {
        if let stream {
            try? awaitCompletion("stopCapture") { stream.stopCapture(completionHandler: $0) }
        }
        videoInput?.markAsFinished()
        if let writer, writer.status == .writing {
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            semaphore.wait()
        }
    }

    // MARK: - completion-handler -> synchronous bridges

    private func shareableContent() throws -> SCShareableContent {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SCShareableContent?
        var failure: Error?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            result = content
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if let failure { throw failure }
        guard let result else { throw DriverError.badConfig("no shareable content") }
        return result
    }

    private func awaitCompletion(_ label: String, _ body: (@escaping (Error?) -> Void) -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        body { error in
            failure = error
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            throw DriverError.badConfig("\(label) failed: \(failure)")
        }
    }
}
