import UIKit // For DispatchQueue, though Foundation is enough

// This struct remains unchanged as it's for the first API call (image-to-text)
struct APIResponse: Codable {
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

class APIHandler {

    let apiKey: String = {
        guard let url  = Bundle.main.url(forResource: "keys", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url),
              let key  = dict["API_KEY"] as? String else {
            fatalError("Missing API_KEY in keys.plist")
        }
        return key
    }()
    
    var prompt: String = "Tell me about the image. Your answer should be a minimum of 40 words."
    var base64ImageString: String?

    // Modified function: completion handler now expects Data? (for audio)
    // Renamed to reflect it generates audio.
    func generateAudioDescription(completion: @escaping (Data?) -> Void) {
        guard let base64Str = self.base64ImageString, !base64Str.isEmpty else {
            print("Error: base64ImageString is nil or empty.")
            completion(nil)
            return
        }

        // --- First API Call: Image to Text ---
        let visionApiURL = URL(string: "https://api.openai.com/v1/responses")! // Using existing endpoint
        var visionRequest = URLRequest(url: visionApiURL)
        visionRequest.httpMethod = "POST"
        visionRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        visionRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let visionParameters: [String: Any] = [
            "model": "o4-mini", // Using existing model
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": self.prompt],
                        [
                            "type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(base64Str)",
                            "detail": "low"
                        ]
                    ]
                ]
            ]
        ]

        visionRequest.httpBody = try? JSONSerialization.data(withJSONObject: visionParameters)

        let visionTask = URLSession.shared.dataTask(with: visionRequest) { data, response, error in
            guard let visionData = data, error == nil else {
                print(error?.localizedDescription ?? "Unknown error in vision API call")
                completion(nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response from vision API")
                completion(nil)
                return
            }
            
            if httpResponse.statusCode == 200 {
                let decoder = JSONDecoder()
                if let apiResponse = try? decoder.decode(APIResponse.self, from: visionData),
                   let messageOutput = apiResponse.output?.first(where: { $0.type == "message" }),
                   let textContent = messageOutput.content?.first(where: { $0.type == "output_text" }),
                   let extractedText = textContent.text, !extractedText.isEmpty {
                    
                    // Text successfully extracted, now call Text-to-Speech API
                    self.fetchSpeechAudio(for: extractedText, completion: completion)
                    
                } else {
                    print("Failed to parse vision API response JSON")
                    if let responseString = String(data: visionData, encoding: .utf8) {
                        print("Vision API Response data: \(responseString)")
                    }
                    completion(nil)
                }
            } else {
                print("Vision API Error: Status Code \(httpResponse.statusCode)")
                if let responseString = String(data: visionData, encoding: .utf8) {
                    print("Vision API Error Response: \(responseString)")
                }
                completion(nil)
            }
        }
        visionTask.resume()
    }

    // --- Second API Call: Text to Speech ---
    private func fetchSpeechAudio(for text: String, completion: @escaping (Data?) -> Void) {
        let ttsApiURL = URL(string: "https://api.openai.com/v1/audio/speech")!
        var ttsRequest = URLRequest(url: ttsApiURL)
        ttsRequest.httpMethod = "POST"
        ttsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        ttsRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let ttsParameters: [String: Any] = [
            "model": "gpt-4o-mini-tts", // Model from curl
            "input": text,
            "voice": "alloy",          // Voice from curl
            "instructions": "Speak very fast.",
            "response_format": "mp3"
        ]

        ttsRequest.httpBody = try? JSONSerialization.data(withJSONObject: ttsParameters)

        let ttsTask = URLSession.shared.dataTask(with: ttsRequest) { data, response, error in
            guard let audioData = data, error == nil else {
                print(error?.localizedDescription ?? "Unknown error in TTS API call")
                completion(nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response from TTS API")
                completion(nil)
                return
            }

            if httpResponse.statusCode == 200 {
                // Audio data received successfully
                DispatchQueue.main.async {
                    completion(audioData)
                }
            } else {
                print("TTS API Error: Status Code \(httpResponse.statusCode)")
                // Attempt to print error message from TTS API response
                if let responseString = String(data: audioData, encoding: .utf8) {
                    print("TTS API Error Response: \(responseString)")
                }
                completion(nil)
            }
        }
        ttsTask.resume()
    }
}
