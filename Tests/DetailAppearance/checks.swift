import Foundation

@main enum DetailAppearanceChecks {
    static func main() {
        let tablets = [CGSize(width: 1024, height: 768), CGSize(width: 1180, height: 820),
                       CGSize(width: 1366, height: 1024)]
        for size in tablets {
            precondition(CatalogDetailLayout.usesWideHero(in: size), "Landscape iPads use two hero columns")
            precondition(CatalogDetailLayout.heroHeight(in: size) <= size.height * 0.56,
                         "The artwork must leave the lower screen available to episodes and cast")
            precondition(CatalogDetailLayout.identityTopInset(in: size) <= 76,
                         "The identity must not start halfway down a landscape iPad")
            let railWidth = CatalogDetailLayout.cardWidth(in: size.width) * 5 + 14 * 4 + 20 * 2
            precondition(railWidth <= size.width + 0.5, "Five episode cards must fit a landscape iPad")
            let actionWidth = CatalogDetailLayout.actionsWidth(in: size.width, wide: true)
            precondition(actionWidth >= 180 + 44 * 4 + 12, "Play and four tool targets must fit together")
            precondition(size.width - 40 - 24 - actionWidth >= 260, "The identity needs its own space")
        }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 390, height: 844),
                     CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 1366)] {
            precondition(!CatalogDetailLayout.usesWideHero(in: size), "Portrait uses stacked hero content")
            precondition(CatalogDetailLayout.identityTopInset(in: size) < CatalogDetailLayout.heroHeight(in: size) / 2,
                         "Portrait identity must remain within the artwork")
            precondition(CatalogDetailLayout.cardWidth(in: size.width) <= size.width - 40,
                         "An episode card must fit even on the smallest phone")
            precondition(CatalogDetailLayout.actionsWidth(in: size.width, wide: false) == size.width - 40,
                         "Stacked actions use the available content width")
        }
        for size in [CGSize(width: 667, height: 375), CGSize(width: 844, height: 390)] {
            precondition(CatalogDetailLayout.heroHeight(in: size) < size.height,
                         "A phone in landscape must not get a portrait-height artwork")
            precondition(CatalogDetailLayout.identityTopInset(in: size) <= 76,
                         "A rotated phone must not retain the portrait top gap")
        }
        print("Detail layout checks passed for landscape iPad, portrait, narrow windows and rotated phones.")
    }
}
