import SwiftUI
import TVCore

#if os(iOS)
struct LocalCatalogDetailEpisode: Identifiable {
    let episode: Episode
    let info: TMDBMatch.EpisodeInfo?
    let title: String
    let numberLabel: String?
    let fileDetail: String?
    let key: LocalCatalogDetailRules.EpisodeKey
    var id: Episode.ID { episode.id }

    static func entries(_ episodes: [Episode], metadata: [Episode.ID: TMDBMatch.EpisodeInfo], details: TMDBMatch.Details?,
                        sourceTitle: String, flag: String, fileDetails: [Episode.ID: String]) -> [Self] {
        let titleSeason = LocalCatalogDetailRules.numbers(flag).season ?? LocalCatalogDetailRules.numbers(sourceTitle).season ?? 1
        let movieTitle = details?.mediaType == .movie ? details?.name : nil
        return episodes.enumerated().map { index, episode in
            let numbers = LocalCatalogDetailRules.numbers(episode.name)
            let info = metadata[episode.id]
            let number = info?.number ?? numbers.episode
            let season = info == nil ? numbers.season ?? titleSeason : details?.season?.number ?? numbers.season ?? titleSeason
            let extra = LocalCatalogDetailRules.isExtra(episode.name)
            let prefix = season == 0 ? "特别篇 · " : season > 1 ? "第 \(season) 季 · " : ""
            let label = movieTitle == nil && !extra ? number.map { prefix + "第 \($0) 集" } : nil
            let title = movieTitle ?? (info?.name.isEmpty == false ? info!.name : episode.name)
            return Self(episode: episode, info: info, title: title, numberLabel: label, fileDetail: fileDetails[episode.id],
                        key: .init(index: index, season: season, number: number, extra: extra))
        }
    }

    static func histories(_ episodes: [Episode], entries: [PlaybackHistoryEntry]) -> [Episode.ID: PlaybackHistoryEntry] {
        let byName = Dictionary(grouping: episodes, by: \.name)
        var result: [Episode.ID: PlaybackHistoryEntry] = [:]
        for entry in entries {
            let matches = (byName[entry.context.episodeName] ?? []).filter { $0.flag == entry.context.episodeFlag }
            let episode = matches.first { $0.id == entry.context.episodeID } ?? (matches.count == 1 ? matches.first : nil)
            guard let episode else { continue }
            if result[episode.id].map({ $0.updatedAt < entry.updatedAt }) ?? true { result[episode.id] = entry }
        }
        return result
    }
}

struct LocalCatalogDetailEpisodeCard: View {
    let value: LocalCatalogDetailEpisode
    let video: Video
    let backdrop: URL?
    let loading: Bool
    var width: CGFloat = 216
    var selected = false
    var progress: Double? = nil
    var watched = false
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    private var overview: String { value.info?.overview.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var metadata: String {
        var parts: [String] = []
        if let date = value.info?.airDate, LocalCatalogDetailRules.date(date) != nil { parts.append(date) }
        if let runtime = value.info?.runtime, runtime.isFinite, runtime > 0 {
            parts.append(runtime.formatted(.number.precision(.fractionLength(0))) + " 分钟")
        }
        if watched { parts.append("已观看") }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        let metadata = self.metadata
        let parts = value.fileDetail?.components(separatedBy: " · ") ?? []
        let size = parts.last.flatMap { part in ["M", "G", "T"].contains(where: part.hasSuffix) ? part : nil }
        let fileDetail = size == nil ? parts.joined(separator: " · ") : parts.dropLast().joined(separator: " · ")
        let summary = value.episode.name == value.title && !overview.isEmpty ? overview : value.episode.name
        VStack(alignment: .leading, spacing: 0) {
            LocalCatalogEpisodeArtwork(primary: value.info?.still ?? backdrop, fallback: video.poster, headers: video.posterHeaders)
                .frame(width: width, height: width * 9 / 16).clipped()
                .overlay {
                    if loading { ProgressView().tint(.white).padding(12).background(.black.opacity(0.5), in: Circle()) }
                }
                .overlay(alignment: .top) { badges(size: size).padding(7) }
                .overlay(alignment: .bottomLeading) {
                    Text(value.title == value.episode.name ? value.numberLabel ?? value.title : value.title)
                        .font(.system(size: captionSize, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                        }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress.isFinite, progress > 0 {
                        ProgressView(value: min(1, progress)).tint(Brand.amber).padding(.horizontal, 8).padding(.bottom, 2)
                    }
                }
            if !metadata.isEmpty || !summary.isEmpty || !fileDetail.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    if !metadata.isEmpty {
                        Text(metadata).font(.system(size: captionSize - 1))
                            .foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    }
                    if !summary.isEmpty {
                        Text(summary).font(.system(size: captionSize)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    }
                    if !fileDetail.isEmpty {
                        Text(fileDetail).font(.system(size: captionSize - 1))
                            .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(.white.opacity(selected ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? .white.opacity(0.95) : .white.opacity(0.06), lineWidth: selected ? 2 : 0.5)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).contentShape(Rectangle())
    }
    private func badges(size: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if let number = value.key.number { badge(String(number)) }
            else if let number = value.numberLabel { badge(number) }
            Spacer(minLength: 0)
            if let size { badge(size) }
        }
    }
    private func badge(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Keep the source poster visible if a TMDB still is missing or its download/decoding fails.
/// Source-specific headers belong only to that source's poster, never to image.tmdb.org.
struct LocalCatalogEpisodeArtwork: View {
    let primary: URL?
    let fallback: URL?
    let headers: [String: String]
    @State private var loaded: CGImage?
    var body: some View {
        ZStack {
            PosterImage(url: fallback, headers: headers, symbol: "play.rectangle")
            if let loaded { Color.clear.overlay { Image(decorative: loaded, scale: 1).resizable().scaledToFill() } }
        }.clipped()
            .task(id: primary) {
                loaded = nil
                guard let primary, primary != fallback else { return }
                let image = await TMDBArtwork.load(primary, maxPixels: 720)
                guard !Task.isCancelled else { return }
                loaded = image
            }
    }
}

struct LocalCatalogDetailEpisodeRow: View {
    let value: LocalCatalogDetailEpisode
    let movie: Bool
    let loading: Bool
    var selected = false
    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill").font(.system(size: 12)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(movie ? value.title : value.numberLabel ?? value.episode.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                if value.episode.name != (movie ? value.title : value.numberLabel ?? value.episode.name) {
                    Text(value.episode.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(.white.opacity(selected ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? Brand.amber.opacity(0.65) : .white.opacity(0.08), lineWidth: 0.75).allowsHitTesting(false) }
            .contentShape(Rectangle())
    }
}
#endif
