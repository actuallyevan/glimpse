import OSLog
import UIKit

private struct VisionAPIRequest: Codable {
    let model: String
    let input: [InputItem]

    struct InputItem: Codable {
        let role: String
        let content: [ContentDetail]
    }

    struct ContentDetail: Codable {
        let type: String
        let text: String?
        let image_url: String?
        let detail: String?
    }
}

private struct VisionAPIResponse: Codable {
    struct OutputItem: Codable {
        struct ContentItem: Codable {
            let type: String?
            let text: String?
        }
        let type: String?
        let content: [ContentItem]?
    }
    let output: [OutputItem]?
}

private struct TTSAPIRequest: Codable {
    let model: String
    let input: String
    let voice: String
    let instructions: String
    let response_format: String
}

class APIHandler {
    private let apiKey: String = {
        guard
            let url = Bundle.main.url(
                forResource: "keys",
                withExtension: "plist"
            ),
            let dict = NSDictionary(contentsOf: url),
            let key = dict["API_KEY"] as? String
        else {
            Logger.logger?.log("Missing API_KEY in keys.plist")
            fatalError("Missing API_KEY in keys.plist")
        }
        return key
    }()

    // Main parameters
    private var visionPrompt: String =
        "You are seeing this for me. Concisely describe what is directly in front of me, and mention key objects to my left and right. Focus on object placement and distance. For example, 'A red mug is in front of you, slightly to your left. Your keys are to your right.' Be direct and brief."
    private var visionImageDetail: String = "auto"
    private var ttsPromptInstructions: String =
        "Speak quickly, calmly, and clearly."
    //

    private let visionAPIURL = URL(
        string: "https://api.openai.com/v1/responses"
    )!
    private let ttsAPIURL = URL(
        string: "https://api.openai.com/v1/audio/speech"
    )!

    func getSpeechFromImage(
        base64ImageString: String,
        completion: @escaping (Data?) -> Void
    ) {
        Logger.logger?.log("Converting image to speech")
        fetchTextFromImage(base64ImageString: base64ImageString) {
            [weak self] extractedText in
            guard let self = self, let text = extractedText, !text.isEmpty
            else {
                Logger.logger?.log(
                    "Failed to get text from image or text is empty"
                )
                completion(nil)
                return
            }
            fetchSpeechFromText(for: text, completion: completion)
        }
    }

    private func fetchTextFromImage(
        base64ImageString: String,
        completion: @escaping (String?) -> Void
    ) {
        Logger.logger?.log("Fetching text from image")
        var request = URLRequest(url: visionAPIURL)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let visionInput = VisionAPIRequest.InputItem(
            role: "user",
            content: [
                VisionAPIRequest.ContentDetail(
                    type: "input_text",
                    text: visionPrompt,
                    image_url: nil,
                    detail: nil
                ),
                VisionAPIRequest.ContentDetail(
                    type: "input_image",
                    text: nil,
                    image_url: "data:image/jpeg;base64,\(base64ImageString)",
                    detail: visionImageDetail
                ),
            ]
        )
        let parameters = VisionAPIRequest(
            model: "o4-mini",
            input: [visionInput]
        )
        request.httpBody = try? JSONEncoder().encode(parameters)

        let task = URLSession.shared.dataTask(with: request) {
            data,
            response,
            error in
            guard let responseData = data, error == nil,
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                Logger.logger?.log(
                    "Vision API request failed. Error: \(error?.localizedDescription ?? "Unknown"), Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
                completion(nil)
                return
            }

            do {
                let apiResponse = try JSONDecoder().decode(
                    VisionAPIResponse.self,
                    from: responseData
                )
                if let messageOutput = apiResponse.output?.first(where: {
                    $0.type == "message"
                }),
                    let textContent = messageOutput.content?.first(where: {
                        $0.type == "output_text"
                    }),
                    let extractedText = textContent.text
                {
                    Logger.logger?.log("Successfully fetched text from image")
                    completion(extractedText)
                } else {
                    Logger.logger?.log(
                        "Failed to parse vision API response JSON or find text content"
                    )
                    completion(nil)
                }
            } catch {
                Logger.logger?.log(
                    "Error decoding vision API response: \(error.localizedDescription)"
                )
                completion(nil)
            }
        }
        task.resume()
    }

    private func fetchSpeechFromText(
        for text: String,
        completion: @escaping (Data?) -> Void
    ) {
        Logger.logger?.log("Fetching speech from text")
        var request = URLRequest(url: ttsAPIURL)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters = TTSAPIRequest(
            model: "gpt-4o-mini-tts",
            input: text,
            voice: "alloy",
            instructions: ttsPromptInstructions,
            response_format: "mp3"
        )
        request.httpBody = try? JSONEncoder().encode(parameters)

        let task = URLSession.shared.dataTask(with: request) {
            data,
            response,
            error in
            guard let audioData = data, error == nil,
                let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                Logger.logger?.log(
                    "TTS API request failed: \(error?.localizedDescription ?? "Unknown"), Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
                completion(nil)
                return
            }
            Logger.logger?.log("Successfully fetched speech audio data")
            completion(audioData)
        }
        task.resume()
    }
}
