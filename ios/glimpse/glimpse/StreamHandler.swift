import CoreBluetooth
import Foundation
import OSLog
import SwiftUI

extension BLEHandler: StreamDelegate {

    // setup l2cap streams
    func setupStreams(for channel: CBL2CAPChannel) {
        guard let inSt = channel.inputStream, let outSt = channel.outputStream
        else { return }

        inputStream = inSt
        outputStream = outSt

        inputStream?.delegate = self
        outputStream?.delegate = self

        inputStream?.schedule(in: .main, forMode: .default)
        outputStream?.schedule(in: .main, forMode: .default)

        inputStream?.open()
        outputStream?.open()

        Logger.logger?.log("Streams created")
    }

    // cleanup l2cap streams
    func cleanupStreams() {

        Logger.logger?.log("Streams closed")

        inputStream?.close()
        inputStream?.remove(from: .main, forMode: .default)
        inputStream?.delegate = nil

        outputStream?.close()
        outputStream?.remove(from: .main, forMode: .default)
        outputStream?.delegate = nil

        l2capChannel = nil
    }

    // handle streams
    func stream(_ aStream: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted:
            bleState = .connected
            Logger.logger?.log(
                "\((self.inputStream == aStream as? InputStream) ? "Input" : "Output") stream opened"
            )

        case .hasBytesAvailable:
            if inputStream == aStream as? InputStream {
                handleAvailableData(on: inputStream!)
            }

        case .hasSpaceAvailable:
            if outputStream == aStream as? OutputStream {
                Logger.logger?.log("Output stream has space available")
                canWriteToOutputStream = true
            }

        case .errorOccurred:
            Logger.logger?.log(
                "Stream error occurred: \(aStream.streamError?.localizedDescription ?? "Unknown error")"
            )
            bleState = .disconnected
            cleanupStreams()

        case .endEncountered:
            Logger.logger?.log("Stream end encountered")
            bleState = .disconnected
            cleanupStreams()

        default:
            break
        }
    }

    private func handleAvailableData(on inputStream: InputStream) {
        if expectedLength == nil {
            guard getImageSize(from: inputStream) else {
                Logger.logger?.log(
                    "Failed to read length or not enough data for length"
                )
                return
            }
        }

        var chunk = [UInt8](repeating: 0, count: mtu)
        let bytesRead = inputStream.read(&chunk, maxLength: chunk.count)

        if bytesRead > 0 {
            imageBuffer.append(chunk, count: bytesRead)
            Logger.logger?.log(
                "Received \(bytesRead) bytes from stream. Total received: \(self.imageBuffer.count)/\(self.expectedLength ?? 0)"
            )
            if let currentExpectedLength = expectedLength,
                imageBuffer.count >= currentExpectedLength
            {
                handleImage(ofSize: currentExpectedLength)
                expectedLength = nil
            }
        } else {
            Logger.logger?.log(
                "Stream read error occurred. Bytes read: \(bytesRead)"
            )
        }
    }

    private func getImageSize(from inputStream: InputStream) -> Bool {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let n = inputStream.read(&lengthBytes, maxLength: 4)

        guard n == 4 else {
            Logger.logger?.log("Could not read 4 bytes for length. Read: \(n)")
            return false
        }

        expectedLength =
            Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8 | Int(lengthBytes[2])
            << 16 | Int(lengthBytes[3]) << 24
        imageBuffer.removeAll(keepingCapacity: true)
        Logger.logger?.log(
            "Successfully read image size: \(self.expectedLength!) bytes"
        )
        return true
    }

    private func handleImage(ofSize imageSize: Int) {
        Logger.logger?.log("Processing image of size: \(imageSize) bytes")
        let imageData = imageBuffer.prefix(imageSize)

        // this background task may not last long enough, but characteristic notification works to ensure data is finished sending
        bgID = UIApplication.shared.beginBackgroundTask(withName: "apiCall") {
            [weak self] in
            guard let self = self else { return }
            Logger.logger?.log("Background task expiration handler called")
            UIApplication.shared.endBackgroundTask(bgID)
        }
        Logger.logger?.log("Background task started: \(self.bgID.rawValue)")

        guard let image = UIImage(data: imageData) else {
            Logger.logger?.log("Failed to create UIImage from data")
            return
        }

        rawImage = image  // to display in debug UI
        Logger.logger?.log(
            "UIImage created successfully. Size: \(image.size.width)x\(image.size.height)"
        )

        let imgBase64 = imageProcessor.processImage(
            image: image,
            radians: Float.pi
        )
        Logger.logger?.log("Image converted to base64, calling api")

        api.getSpeechFromImage(base64ImageString: imgBase64) {
            [weak self] receivedAudioData in
            guard let self = self else { return }

            if let audioData = receivedAudioData {
                Logger.logger?.log(
                    "Received audio data of length: \(audioData.count) bytes"
                )
                sendAudioData(audioData: audioData) { success in
                    Logger.logger?.log(
                        "Audio send completed. Success: \(success). Ending background task"
                    )
                    UIApplication.shared.endBackgroundTask(self.bgID)
                }
            } else {
                Logger.logger?.log(
                    "No audio data received from API. Ending background task"
                )
                UIApplication.shared.endBackgroundTask(self.bgID)
            }
        }
    }

    // send chunked audio data
    private func sendAudioData(
        audioData: Data,
        completion: @escaping (Bool) -> Void
    ) {

        var length = UInt32(audioData.count).littleEndian
        let lengthHeader = Data(
            bytes: &length,
            count: MemoryLayout<UInt32>.size
        )

        let dataToSend: Data? = lengthHeader + audioData
        var sendOffset = 0

        audioSendCompletionHandler = completion

        guard let outSt = self.outputStream, let currentData = dataToSend else {
            Logger.logger?.log(
                "No data to send or output stream is not available"
            )
            audioSendCompletionHandler?(false)
            audioSendCompletionHandler = nil
            return
        }

        Logger.logger?.log(
            "Prepared audio data for sending: \(dataToSend!.count) bytes"
        )

        currentData.withUnsafeBytes {
            (rawBufferPointer: UnsafeRawBufferPointer) -> Void in
            let typedBufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
            guard let basePtr = typedBufferPointer.baseAddress else {
                Logger.logger?.log("Failed to get base address for audio data")
                audioSendCompletionHandler?(false)
                audioSendCompletionHandler = nil
                return
            }

            while canWriteToOutputStream && sendOffset < currentData.count {
                let bytesRemaining = currentData.count - sendOffset
                let amountToWrite = min(mtu, bytesRemaining)

                let chunkPointer = basePtr.advanced(by: sendOffset)

                let written = outSt.write(
                    chunkPointer,
                    maxLength: amountToWrite
                )

                if written > 0 {
                    sendOffset += written
                    Logger.logger?.log(
                        "Sent \(written) bytes of audio packet. Total sent: \(sendOffset)/\(currentData.count)"
                    )

                    if sendOffset == currentData.count {
                        Logger.logger?.log("Audio data packet sent")
                        audioSendCompletionHandler?(true)
                        audioSendCompletionHandler = nil
                        break
                    }
                } else {
                    Logger.logger?.log(
                        "Error sending audio data: \(outSt.streamError?.localizedDescription ?? "Unknown error")"
                    )
                    audioSendCompletionHandler?(false)
                    audioSendCompletionHandler = nil
                    break
                }
            }
        }
    }
}
