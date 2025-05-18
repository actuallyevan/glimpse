import OSLog
import UIKit

class JPEGHandler {

    private func rotate(image: UIImage, radians: Float) -> UIImage? {
        var newSize = CGRect(origin: CGPoint.zero, size: image.size).applying(
            CGAffineTransform(rotationAngle: CGFloat(radians))
        ).size
        // Trim off the extremely small float value to prevent core graphics from rounding it up
        newSize.width = floor(newSize.width)
        newSize.height = floor(newSize.height)

        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        // Move origin to middle
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        // Rotate around middle
        context.rotate(by: CGFloat(radians))
        // Draw the image at its center
        image.draw(
            in: CGRect(
                x: -image.size.width / 2,
                y: -image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
        )

        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return newImage
    }

    private func convertToBase64(image: UIImage) -> String {
        return image.jpegData(compressionQuality: 1.0)?.base64EncodedString()
            ?? ""
    }

    // rotates and converts image to base64 to prepare for API call
    func processImage(image: UIImage, radians: Float) -> String {
        guard let rotatedImage = rotate(image: image, radians: radians) else {
            Logger.logger?.log("Failed to rotate image")
            return ""
        }

        let base64String = convertToBase64(image: rotatedImage)
        Logger.logger?.log("Processed image")
        return base64String
    }
}
