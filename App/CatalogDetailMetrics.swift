import Foundation

enum CatalogDetailLayout {
    static func usesWideHero(in size: CGSize) -> Bool {
        size.width >= 700 && size.width > size.height
    }

    static func heroHeight(in size: CGSize) -> CGFloat {
        if usesWideHero(in: size) { return min(400, max(280, size.height * 0.52)) }
        if size.width > size.height { return min(360, max(260, size.height * 0.8)) }
        if size.width >= 700 { return min(540, max(400, size.width * 0.66)) }
        return min(500, max(380, size.width * 1.1))
    }

    static func identityTopInset(in size: CGSize) -> CGFloat {
        if usesWideHero(in: size) { return min(66, max(50, size.height * 0.075)) }
        if size.width > size.height { return max(50, min(76, size.height * 0.15)) }
        if size.width >= 700 { return min(180, max(112, size.width * 0.2)) }
        return min(190, max(132, size.width * 0.42))
    }

    static func cardWidth(in width: CGFloat) -> CGFloat {
        width >= 900 ? min(232, max(180, (width - 96) / 5)) : min(232, max(180, width * 0.58))
    }

    static func actionsWidth(in width: CGFloat, wide: Bool) -> CGFloat {
        wide ? min(440, max(368, (width - 40) * 0.4)) : max(0, width - 40)
    }
}
