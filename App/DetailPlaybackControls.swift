import SwiftUI
import Foundation
import TVCore

#if os(iOS)
/// History selects Play or Resume; replay can sit beside it or in the caller's menu.
struct DetailPlaybackControls: View {
    let selection: DetailPlaybackSelection
    let busy: Bool
    let loadingMode: PlaybackResumeMode?
    var showsBeginningButton = true
    let start: (PlaybackResumeMode) -> Void

    private var resumePosition: Double? { selection.position(for: .resume) }
    private var reading: ReadingHistoryProgress? { selection.readingProgress }
    private var canResume: Bool { selection.canResume }
    private var finishedReading: Bool { reading != nil && selection.history?.completed == true }
    private var beginningLabel: String { reading == nil ? "从 00:00 开始" : "从第 1 页开始" }
    private var progress: Double {
        guard let value = selection.history?.progress, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
    var body: some View {
        HStack(spacing: 8) {
            if showsBeginningButton && canResume && !finishedReading {
                Button { start(.beginning) } label: {
                    Group {
                        if busy && loadingMode == .beginning { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .medium)) }
                    }.frame(width: 44, height: 48).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(.white.opacity(0.10), in: Capsule())
                .disabled(busy || selection.episode == nil)
                .accessibilityLabel(reading == nil ? "从头播放" : "重新阅读")
                .accessibilityValue(beginningLabel).accessibilityIdentifier("detail.playBeginning")
            }
            action(.resume, title: reading == nil ? (canResume ? "继续播放" : "开始播放") : (finishedReading ? "重新阅读" : "继续阅读"),
                   subtitle: context, symbol: reading == nil ? "play.fill" : "book.fill")
                .background { CatalogPlaybackBackground() }
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .opacity(busy || selection.episode == nil ? 0.65 : 1)
        .accessibilityElement(children: .contain).accessibilityLabel("播放模式")
    }
    private var context: String {
        if finishedReading { return [episodeContext, beginningLabel].compactMap { $0 }.joined(separator: " · ") }
        let position = reading.map { "第 \($0.page + 1) / \($0.totalPages) 页" } ?? resumePosition.map(time)
        return [episodeContext, position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var episodeContext: String? {
        guard let episode = selection.episode else { return nil }
        guard reading == nil, let number = LocalDetailEpisodeNumbers.numbers(episode.name).episode else { return episode.name }
        let season = LocalDetailEpisodeNumbers.numbers(episode.name).season
        return (season.flatMap { $0 > 1 ? "第 \($0) 季 · " : nil } ?? "") + "第 \(number) 集"
    }
    private func action(_ mode: PlaybackResumeMode, title: String, subtitle: String, symbol: String) -> some View {
        Button { start(mode) } label: {
            VStack(spacing: 5) {
                CatalogPlaybackLabel(title: title, subtitle: subtitle, symbol: symbol, loading: busy && loadingMode == mode)
                if canResume {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Brand.amber)
                        .padding(.horizontal, 10)
                }
            }
            .foregroundStyle(.black)
            .padding(.vertical, canResume ? 6 : 0)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy || selection.episode == nil)
        .accessibilityLabel(title + " " + (selection.episode?.name ?? ""))
        .accessibilityValue(canResume ? "\(context)，\(reading == nil ? "观看进度" : "阅读进度") \(Int((progress * 100).rounded()))%" : context)
        .accessibilityIdentifier(mode == .beginning ? "detail.playBeginning" : "detail.play")
    }
    private func time(_ position: Double) -> String {
        let value = Int(position.isFinite ? min(Double(Int.max / 2), max(0, position)) : 0)
        return value >= 3_600 ? String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
                             : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
#endif
