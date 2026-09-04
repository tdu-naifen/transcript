import AVFoundation
import Foundation

struct AudioInputOption: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
}

enum AudioInputs {
    static func available() -> [AudioInputOption] {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        return inputs.map { port in
            AudioInputOption(id: port.uid, name: port.portName, symbol: symbol(for: port.portType))
        }
    }

    static func currentId() -> String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
    }

    static func select(_ option: AudioInputOption) {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == option.id }) else { return }
        try? session.setPreferredInput(port)
    }

    private static func symbol(for type: AVAudioSession.Port) -> String {
        switch type {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: "airpods"
        case .headsetMic, .headphones: "headphones"
        case .usbAudio: "cable.connector"
        default: "mic"
        }
    }
}
