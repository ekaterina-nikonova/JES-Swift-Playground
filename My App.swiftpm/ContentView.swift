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




struct ContentView: View {
    @State private var handwritingDrawing = PKDrawing()
    @State private var previewImage: UIImage?
    @State private var topicText: String = ""
    
    @State private var imageToShareURL: URL?
    @State private var isShowingShareSheet = false
    
    @StateObject private var audioRecorder = AudioRecorder()
    
    @State private var audioToShareURL: URL?            
    @State private var isShowingAudioShareSheet = false 
    
    var body: some View {
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
                    // For now, just log or update UI
                    print("Topic to send: \(topicText)")
                    // TODO: later, send topicText to JES server
                }
                .buttonStyle(.borderedProminent)
                .disabled(topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            

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

#Preview {
    ContentView()
}
