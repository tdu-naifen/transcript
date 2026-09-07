import SwiftUI
import XCTest
import TranscriptCore
@testable import Transcript

@MainActor
final class LiveDynamicSpeakerStatusRenderingQATests: XCTestCase {
    func testOptionalLiveStatusesRenderWithoutRecordingOrModelWork() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/ios-recovered-independent-qa/live-dynamic/render-\(UUID().uuidString)")
        let database = try AppDatabase.inMemory()
        let store = try AudioFileStore.standard(applicationSupport: root)
        let services = try AppServices(database: database, store: store, captureEngine: LifecycleCaptureEngine())
        let meeting = Meeting(title: "Rendering only", startedAt: Date(), state: .recording, originDeviceId: "qa")
        try await MeetingRepository(database).insert(meeting)
        let model = TranscriptionModel(services: services, meetingId: meeting.id, asrFinish: {}, diarizationFinish: {})
        XCTAssertNil(services.makeLiveSpeakers(meetingID: meeting.id))
        let localization = LocalizationManager.shared
        let originalLanguage = localization.language
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            localization.language = originalLanguage
        }
        addTeardownBlock { @MainActor in
            await model.discard()
            services.session.invalidate()
            try database.writer.close()
            try FileManager.default.removeItem(at: root)
        }
        let states: [(String, LiveSpeakerStatus)] = [
            ("context", .waitingForContext), ("preparing", .preparingModels),
            ("paused", .paused), ("busy", .busy), ("models", .modelsUnavailable),
            ("inference", .processingFailed), ("storage", .storageFailed), ("capacity", .capacityReached)
        ]
        for language in [AppLanguage.en, .zhHans] {
            localization.language = language
            let locale = language == .en ? "en" : "zh-Hans"
            let controller = UIHostingController(rootView:
                NavigationStack { LiveTranscriptView(model: model).navigationTitle("Live status") }
                    .environment(\.locale, Locale(identifier: locale))
            )
            window.rootViewController = controller
            window.makeKeyAndVisible()
            for (name, state) in states {
                await model.apply(state, meetingId: meeting.id)
                XCTAssertNotNil(model.speakerWarning)
                XCTAssertFalse(model.isIdentifyingSpeakers)
                XCTAssertNil(model.processingIssue)
                guard ["context", "busy", "storage"].contains(name) else { continue }
                try await Task.sleep(for: .milliseconds(350))
                controller.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertGreaterThan(image.size.width, 0)
                let attachment = XCTAttachment(image: image)
                attachment.name = "live-status-\(locale)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
