import SwiftUI
import Foundation
import TVCore

#if os(iOS)
/// An unwatched episode has one action. Resumable history adds an explicit zero-time replay.
struct DetailPlaybackControls: View {
    let selection: DetailPlaybackSelection
    let busy: Bool
    let loadingMode: PlaybackResumeMode?
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
            if canResume && !finishedReading {
                Button { start(.beginning) } label: {
                    Group {
                        if busy && loadingMode == .beginning { ProgressView().tint(.white) }
                        else { Image(systemName: "arrow.counterclockwise").font(.system(size: 17, weight: .medium)) }
                    }.frame(width: 44, height: 58).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .background(.white.opacity(0.10), in: Capsule())
                .disabled(busy || selection.episode == nil)
                .accessibilityLabel(reading == nil ? "从头播放" : "重新阅读")
                .accessibilityValue(beginningLabel).accessibilityIdentifier("detail.playBeginning")
            }
            action(.resume, title: reading == nil ? (canResume ? "继续播放" : "开始播放") : (finishedReading ? "重新阅读" : "继续阅读"),
                   subtitle: context, symbol: reading == nil ? "play.fill" : "book.fill")
                .background(.white, in: Capsule())
                .overlay(alignment: .bottom) {
                    if canResume {
                        ProgressView(value: progress).tint(Brand.amber)
                            .padding(.horizontal, 26).padding(.bottom, 5)
                            .accessibilityLabel(reading == nil ? "观看进度" : "阅读进度")
                            .accessibilityValue("\(Int((progress * 100).rounded()))%")
                    }
                }
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity)
        .opacity(busy || selection.episode == nil ? 0.65 : 1)
        .accessibilityElement(children: .contain).accessibilityLabel("播放模式")
    }
    private var context: String {
        if finishedReading { return [selection.episode?.name, beginningLabel].compactMap { $0 }.joined(separator: " · ") }
        let position = reading.map { "第 \($0.page + 1) / \($0.totalPages) 页" } ?? resumePosition.map(time)
        return [selection.episode?.name, position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func action(_ mode: PlaybackResumeMode, title: String, subtitle: String, symbol: String) -> some View {
        Button { start(mode) } label: {
            HStack(spacing: 8) {
                if busy && loadingMode == mode { ProgressView().controlSize(.small).tint(.black) }
                else { Image(systemName: symbol).font(.system(size: 19, weight: .semibold)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(.black.opacity(0.58)).lineLimit(1) }
                }
            }.foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 58, alignment: .center).padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(busy || selection.episode == nil)
        .accessibilityLabel(title + " " + (selection.episode?.name ?? ""))
        .accessibilityValue(mode == .beginning ? beginningLabel : context)
        .accessibilityIdentifier(mode == .beginning ? "detail.playBeginning" : "detail.play")
    }
    private func time(_ position: Double) -> String {
        let value = Int(position.isFinite ? min(Double(Int.max / 2), max(0, position)) : 0)
        return value >= 3_600 ? String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
                             : String(format: "%02d:%02d", value / 60, value % 60)
    }
}
#endif
