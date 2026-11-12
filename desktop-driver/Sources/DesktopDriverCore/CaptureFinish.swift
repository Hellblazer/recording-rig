// SPDX-License-Identifier: MIT
//
// What the capture sink may do at finish, from the asset writer's status. The
// writer's input may be marked finished only while the writer is writing: on a
// run where no complete frame ever arrived the session was never started, the
// status is still "unknown", and AVFoundation raises an ObjC exception that
// aborts the driver after an otherwise good run.

public enum CaptureFinish {
    /// AVAssetWriter.Status raw values, mirrored so the policy needs no AVFoundation import.
    public static let writerStatusUnknown = 0
    public static let writerStatusWriting = 1

    /// True when the input may be marked finished and the writer asked to finish.
    public static func mayFinishWriting(writerStatus: Int) -> Bool {
        writerStatus == writerStatusWriting
    }
}
