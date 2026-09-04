import Foundation
import TranscriptCore

#if DEBUG
/// Seeds realistic fake meetings + speaker-attributed transcripts so list/detail layout
/// can be judged against real density instead of the ASCII mockups in UI.md (§6.1):
/// `xcrun simctl launch booted com.transcript.Transcript -uiFixture 1`
///
/// Idempotent: bails out before writing anything if the marker meeting already exists.
enum UIFixture {
    static func seedIfRequested(services: AppServices) async {
        guard UserDefaults.standard.integer(forKey: "uiFixture") == 1 else { return }

        let meetingRepo = MeetingRepository(services.database)
        let speakerRepo = SpeakerRepository(services.database)
        let utteranceRepo = UtteranceRepository(services.database)
        let deviceId = services.deviceId

        do {
            guard try await meetingRepo.fetch(id: markerMeetingId) == nil else { return }
            let speakers = try await makeSpeakers(speakerRepo, deviceId: deviceId)
            try await makeMeetings(
                meetingRepo: meetingRepo,
                speakerRepo: speakerRepo,
                utteranceRepo: utteranceRepo,
                speakers: speakers,
                deviceId: deviceId
            )
        } catch {
            // DEBUG-only convenience; a failure here should never block launch.
        }
    }

    /// First meeting created; its presence means the whole fixture already ran.
    private static let markerMeetingId = "fixture-meeting-standup"

    private struct FixtureSpeakers {
        let alexandra: Speaker
        let marmot: Speaker
        let wei: Speaker
        let puffin: Speaker
        let badger: Speaker
        let jane: Speaker
    }

    private static func makeSpeakers(_ repo: SpeakerRepository, deviceId: String) async throws -> FixtureSpeakers {
        func speaker(id: String, displayName: String?, anonymousName: String, colorIndex: Int) -> Speaker {
            Speaker(
                id: id, displayName: displayName, anonymousName: anonymousName,
                colorIndex: colorIndex, originDeviceId: deviceId
            )
        }

        // Long user-given names vs short animal names (task requirement); a mix of
        // named and still-anonymous speakers.
        let speakers = FixtureSpeakers(
            alexandra: speaker(
                id: "fixture-speaker-alexandra", displayName: "Alexandra Beatrix Montgomery-Okafor",
                anonymousName: "Hippo", colorIndex: 0
            ),
            marmot: speaker(id: "fixture-speaker-marmot", displayName: nil, anonymousName: "Marmot", colorIndex: 1),
            wei: speaker(id: "fixture-speaker-wei", displayName: "小伟", anonymousName: "Otter", colorIndex: 2),
            puffin: speaker(id: "fixture-speaker-puffin", displayName: nil, anonymousName: "Puffin", colorIndex: 3),
            badger: speaker(id: "fixture-speaker-badger", displayName: nil, anonymousName: "Badger", colorIndex: 4),
            jane: speaker(
                id: "fixture-speaker-jane", displayName: "Dr. Jane Wanjiru Kariuki-Bergström",
                anonymousName: "Wren", colorIndex: 5
            )
        )
        for speaker in [speakers.alexandra, speakers.marmot, speakers.wei, speakers.puffin, speakers.badger, speakers.jane] {
            try await repo.upsert(speaker)
        }
        return speakers
    }

    private static func makeMeetings(
        meetingRepo: MeetingRepository,
        speakerRepo: SpeakerRepository,
        utteranceRepo: UtteranceRepository,
        speakers: FixtureSpeakers,
        deviceId: String
    ) async throws {
        let now = Date()

        func meeting(id: String, title: String, startedAt: Date, durationMs: Int) -> Meeting {
            Meeting(
                id: id, title: title, startedAt: startedAt, durationMs: durationMs,
                state: .recorded, originDeviceId: deviceId
            )
        }

        func line(_ meetingId: String, _ startMs: Int, _ endMs: Int, _ speaker: Speaker, _ text: String, _ locale: String) -> Utterance {
            Utterance(
                meetingId: meetingId, startMs: startMs, endMs: endMs, text: text,
                speakerId: speaker.id, localeIdentifier: locale, originDeviceId: deviceId
            )
        }

        // 3-minute 1:1 — the shortest meeting, two speakers.
        let oneOnOne = meeting(
            id: "fixture-meeting-1on1", title: "1:1 with Alexandra",
            startedAt: now.addingTimeInterval(-2 * 86_400), durationMs: 3 * 60_000
        )
        // Weekly standup — the idempotency marker, four speakers.
        let standup = meeting(
            id: markerMeetingId, title: "周会",
            startedAt: now.addingTimeInterval(-86_400), durationMs: 32 * 60_000 + 11_000
        )
        // Client call — two speakers.
        let clientCall = meeting(
            id: "fixture-meeting-client-call", title: "客户电话",
            startedAt: now.addingTimeInterval(-5 * 3_600), durationMs: 45 * 60_000 + 30_000
        )
        // 90-minute quarterly review — the longest meeting, four speakers.
        let review = meeting(
            id: "fixture-meeting-review-90min", title: "季度评审",
            startedAt: now.addingTimeInterval(-10 * 86_400), durationMs: 90 * 60_000
        )
        // Solo memo — the only single-speaker meeting.
        let soloMemo = meeting(
            id: "fixture-meeting-solo-memo", title: "个人笔记",
            startedAt: now.addingTimeInterval(-3 * 3_600), durationMs: 8 * 60_000
        )

        for m in [oneOnOne, standup, clientCall, review, soloMemo] {
            try await meetingRepo.insert(m)
        }

        func attach(_ meeting: Meeting, _ participants: [Speaker]) async throws {
            for (index, speaker) in participants.enumerated() {
                try await speakerRepo.assignDisplayIndex(
                    meetingId: meeting.id, speakerId: speaker.id, displayIndex: index, deviceId: deviceId
                )
            }
        }

        try await attach(oneOnOne, [speakers.alexandra, speakers.marmot])
        try await attach(standup, [speakers.alexandra, speakers.wei, speakers.puffin, speakers.badger])
        try await attach(clientCall, [speakers.wei, speakers.puffin])
        try await attach(review, [speakers.alexandra, speakers.marmot, speakers.wei, speakers.badger])
        try await attach(soloMemo, [speakers.jane])

        try await utteranceRepo.append([
            line(oneOnOne.id, 5_000, 9_500, speakers.alexandra, "Hey, 最近还好吗?想聊聊你在 onboarding 里遇到的问题。", "zh-CN"),
            line(oneOnOne.id, 40_000, 45_000, speakers.marmot, "还不错,就是 documentation 有点少, I had to guess a lot of things.", "en-US"),
            line(oneOnOne.id, 80_000, 84_000, speakers.alexandra, "Got it, 我会让团队补充一下 docs。", "zh-CN"),
            line(oneOnOne.id, 150_000, 154_000, speakers.marmot, "Thanks, that would really help 新人。", "en-US"),

            line(standup.id, 15_000, 20_000, speakers.alexandra, "Let's kick off, 大家先同步一下 sprint 的进度吧。", "zh-CN"),
            line(standup.id, 42_000, 48_000, speakers.wei, "我这边 API 的 latency 有点高,可能是 database connection pool 太小了。", "zh-CN"),
            line(standup.id, 70_000, 75_000, speakers.puffin, "Should we bump the pool size, or switch to async processing altogether?", "en-US"),
            line(standup.id, 95_000, 100_000, speakers.badger, "我建议先 profile 一下,不要瞎猜 bottleneck 在哪。", "zh-CN"),
            line(standup.id, 920_000, 926_000, speakers.alexandra, "Good point. Let's revisit this after lunch and 再决定要不要重构。", "en-US"),
            line(standup.id, 1_910_000, 1_915_000, speakers.wei, "行,那就这样,下次会议见。", "zh-CN"),

            line(clientCall.id, 20_000, 25_000, speakers.wei, "谢谢您抽时间,我们先过一下上次讨论的 pricing model。", "zh-CN"),
            line(clientCall.id, 312_000, 318_000, speakers.puffin, "Sure. We were hoping for something closer to a usage-based tier, 而不是固定月费。", "en-US"),
            line(clientCall.id, 1_200_000, 1_205_000, speakers.wei, "明白,我们可以给您准备一个 custom quote。", "zh-CN"),
            line(clientCall.id, 2_690_000, 2_694_000, speakers.puffin, "Sounds good, looking forward to it.", "en-US"),

            line(review.id, 30_000, 36_000, speakers.alexandra, "欢迎大家参加这次 quarterly review,今天议程比较满。", "zh-CN"),
            line(review.id, 735_000, 742_000, speakers.marmot, "Our churn rate dropped by three points 这个季度,主要是因为 onboarding 改进了。", "en-US"),
            line(review.id, 2_700_000, 2_708_000, speakers.wei, "从 engineering 角度看,我们把 build time 从 40 分钟降到了 12 分钟。", "zh-CN"),
            line(review.id, 3_820_000, 3_826_000, speakers.badger, "Nice work. 那接下来 Q 的 roadmap 是什么?", "en-US"),
            line(review.id, 5_350_000, 5_356_000, speakers.alexandra, "我们会后再对齐,谢谢大家,今天先到这里。", "zh-CN"),

            line(soloMemo.id, 10_000, 15_000, speakers.jane, "今天 client meeting 的 follow-up:需要发一份 summary 给 stakeholders。", "zh-CN"),
            line(soloMemo.id, 225_000, 231_000, speakers.jane, "Also remember to update the roadmap doc before Friday.", "en-US"),
            line(soloMemo.id, 440_000, 443_000, speakers.jane, "That's all for now.", "en-US")
        ])
    }
}
#endif
