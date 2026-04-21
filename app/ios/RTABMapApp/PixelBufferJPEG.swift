//
//  PixelBufferJPEG.swift
//  RTABMapApp
//
//  Convert ARKit's CVPixelBuffer (YCbCr bi-planar, 420f) to a JPEG Data blob.
//

import CoreImage
import ImageIO
import UIKit

enum PixelBufferJPEGError: Error {
    case encodingFailed
}

enum PixelBufferJPEG {

    /// Returns JPEG data rotated into display orientation.
    /// - Parameters:
    ///   - pixelBuffer: ARKit frame.capturedImage, retained by caller.
    ///   - interfaceOrientation: UI orientation at capture time.
    ///   - quality: 0.0 ... 1.0 (0.85 recommended).
    static func jpeg(
        from pixelBuffer: CVPixelBuffer,
        interfaceOrientation: UIInterfaceOrientation,
        quality: CGFloat
    ) throws -> Data {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = ci.oriented(cgImagePropertyOrientation(for: interfaceOrientation))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = ctx.jpegRepresentation(
            of: oriented,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else {
            throw PixelBufferJPEGError.encodingFailed
        }
        return data
    }

    /// ARKit captures in sensor orientation (landscape-right natural). Map to display orientation.
    private static func cgImagePropertyOrientation(
        for orientation: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:            return .right
        case .portraitUpsideDown:  return .left
        case .landscapeLeft:       return .down    // home button on right
        case .landscapeRight:      return .up      // home button on left (natural)
        case .unknown:             return .right
        @unknown default:          return .right
        }
    }
}
