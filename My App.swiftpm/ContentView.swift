import SwiftUI
import PencilKit
import AVFAudio

struct HandwritingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    
    class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: HandwritingCanvas
        
        init(parent: HandwritingCanvas) {
            self.parent = parent
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Push the current canvas drawing into the SwiftUI state
            parent.drawing = canvasView.drawing
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen,
                                   color: UIColor.systemIndigo,
                                   width: 3.0)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        
        canvas.delegate = context.coordinator   // <- important
        return canvas
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.drawing = drawing
    }
}

@discardableResult
func saveHandwritingImage(_ image: UIImage) -> URL? {
    guard let pngData = image.pngData() else {
        print("Failed to create PNG data")
        return nil
    }
    
    guard let documentsDirectory = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        print("Could not find Documents directory")
        return nil
    }
    
    let fileURL = documentsDirectory.appendingPathComponent("handwriting.png")
    
    do {
        try pngData.write(to: fileURL)
        print("Saved handwriting PNG at:", fileURL.path)
        return fileURL
    } catch {
        print("Error saving PNG:", error.localizedDescription)
        return nil
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items,
                                 applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController,
                                context: Context) {
        // nothing to update
    }
}


class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordedFileURL: URL?
    
    private var audioRecorder: AVAudioRecorder?
    
    override init() {
        super.init()
        configureSession()
    }
    
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("Audio session error:", error.localizedDescription)
        }
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
    
    func startRecording() {
        requestPermission { [weak self] granted in
            guard let self, granted else {
                print("Microphone access not granted")
                return
            }
            
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,                    // 16 kHz
                AVNumberOfChannelsKey: 1,                    // mono
                AVLinearPCMBitDepthKey: 16,                  // 16‑bit
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]                                             // uncompressed PCM (WAV)[web:273][web:285]
            
            // Save to Documents as handwriting.wav
            guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                           in: .userDomainMask).first else {
                print("No documents directory")
                return
            }
            let fileURL = documents.appendingPathComponent("handwriting.wav")
            
            do {
                audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
                audioRecorder?.prepareToRecord()
                audioRecorder?.record()
                recordedFileURL = fileURL
                isRecording = true
                print("Recording to:", fileURL.path)
            } catch {
                print("Failed to start recording:", error.localizedDescription)
            }
        }
    }
    
    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
    }
}


// Networking

struct GenerateRequest: Codable {
    let topic: String
}

struct GenerateResponse: Codable {
    let text: String
    let questions: [String]
}


func sendTopic(_ topic: String,
               completion: @escaping (Result<GenerateResponse, Error>) -> Void) {
    guard let url = URL(string: "http://192.168.84.40:8000/generate-testz") else {
        return
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")
    
    let body = GenerateRequest(topic: topic)
    
    do {
        let jsonData = try JSONEncoder().encode(body)
        request.httpBody = jsonData
    } catch {
        completion(.failure(error))
        return
    }
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
            return
        }
        
        guard let data = data else {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "JES",
                                            code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "No data"])))
            }
            return
        }
        
        do {
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            DispatchQueue.main.async {
                completion(.success(decoded))
            }
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }.resume()
}



struct ContentView: View {
    @State private var handwritingDrawing = PKDrawing()
    @State private var previewImage: UIImage?
    @State private var topicText: String = ""
    
    @State private var imageToShareURL: URL?
    @State private var isShowingShareSheet = false
    
    @StateObject private var audioRecorder = AudioRecorder()
    
    @State private var audioToShareURL: URL?            
    @State private var isShowingAudioShareSheet = false
    
    // Networking: getting the text and a list of questions
    @State private var generatedText: String = ""
    @State private var generatedQuestions: [String] = []
    @State private var selectedQuestionIndex: Int? = nil
    @State private var isLoadingTopic = false 
    @State private var topicErrorMessage: String? = nil
    
    var body: some View {
        ScrollView {
            VStack {
                Text("Japanese Language 🇯🇵 Exercise System")
                    .font(.title)
                
                
                Text("Type in a topic for the exercise:")
                    .font(.headline)
                
                HStack {
                    TextField("日本語を使ってください。", text: $topicText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                    
                    Button("Send") {
                        let trimmed = topicText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        
                        isLoadingTopic = true
                        topicErrorMessage = nil
                        generatedText = ""
                        generatedQuestions = []
                        
                        sendTopic(trimmed) { result in
                            isLoadingTopic = false
                            switch result {
                            case .success(let response):
                                generatedText = response.text
                                generatedQuestions = response.questions
                            case .failure(let error):
                                topicErrorMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingTopic)
                }
                .padding(.horizontal)
                
                if isLoadingTopic {
                    ProgressView("Generating exercise...")
                        .padding(.top, 8)
                }
                
                if let error = topicErrorMessage {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                        .font(.footnote)
                        .padding(.top, 4)
                }
                
                if !generatedText.isEmpty {
                    Text("Generated text:")
                        .font(.headline)
                        .padding(.top, 12)
                    
                    ScrollView {
                        // Try to parse Markdown; fall back to plain text if it fails
                        if let attributed = try? AttributedString(markdown: generatedText) {
                            Text(attributed)
                                .font(.body)
                        } else {
                            Text(generatedText)
                                .font(.body)
                        }
                        
                        Text(generatedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(minHeight: 200, maxHeight: 300) // ~10+ lines visible, then scroll
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
                
                if !generatedQuestions.isEmpty {
                    Text("Questions:")
                        .font(.headline)
                        .padding(.top, 8)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(generatedQuestions.enumerated()), id: \.offset) { index, question in
                            Button {
                                selectedQuestionIndex = index
                                print("Selected question:", question)
                                // TODO: bind this to the JES answer flow
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                    Text(question)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    (selectedQuestionIndex == index)
                                    ? Color.blue.opacity(0.15)
                                    : Color.clear
                                )
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
                
                Text("Write the answer below:")
                    .font(.headline)
                
                HandwritingCanvas(drawing: $handwritingDrawing)
                    .frame(height: 300)
                    .background(Color.white)
                    .cornerRadius(10)
                    .padding()
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white, lineWidth: 2))
                
                // Export Button (saves as PNG)
                Button("Export as PNG") {
                    let bounds = handwritingDrawing.bounds.insetBy(dx: -10, dy: -10)
                    if !handwritingDrawing.strokes.isEmpty {
                        let image = handwritingDrawing.image(from: bounds,
                                                             scale: UIScreen.main.scale)
                        let fileURL = saveHandwritingImage(image)
                        
                        // Suggest to export the PNG file
                        previewImage = image
                        imageToShareURL = fileURL
                        isShowingShareSheet = true
                        
                        // TODO: Upload image.pngData() to server later
                    } else {
                        print("No strokes to export")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(handwritingDrawing.strokes.isEmpty)
                
                // Clear Button
                Button("Clear") {
                    handwritingDrawing = PKDrawing()
                }
                
                // Audio
                // Audio recording section
                Text("Record your spoken answer:")
                    .font(.headline)
                    .padding(.top)
                
                HStack {
                    Button(audioRecorder.isRecording ? "Stop Recording" : "Start Recording") {
                        if audioRecorder.isRecording {
                            audioRecorder.stopRecording()
                        } else {
                            audioRecorder.startRecording()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Export WAV") {
                        if let url = audioRecorder.recordedFileURL {
                            audioToShareURL = url
                            isShowingAudioShareSheet = true
                        } else {
                            print("No recording to export")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(audioRecorder.recordedFileURL == nil)
                }
                
            }
            .padding()
            .sheet(isPresented: $isShowingShareSheet) {
                if let url = imageToShareURL {
                    ShareSheet(items: [url])
                }
            }
            .sheet(isPresented: $isShowingAudioShareSheet) {
                if let url = audioToShareURL {
                    ShareSheet(items: [url])   // handwriting.wav
                }
            }
        }
    }

        }
       
#Preview {
    ContentView()
}
