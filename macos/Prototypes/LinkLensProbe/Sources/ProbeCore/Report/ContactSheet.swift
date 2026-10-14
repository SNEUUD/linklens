import Foundation

/// Builds a self-contained local HTML contact sheet from a report.
/// Thumbnail paths are relative to the report folder, so the HTML must sit next to `thumbs/`.
public enum ContactSheet {
    public static func html(for report: AnalysisReport) -> String {
        var blocks: [String] = []
        var index = 0
        let photos = report.photos
        while index < photos.count {
            if let burstId = photos[index].burstId {
                var members: [PhotoResult] = []
                while index < photos.count, photos[index].burstId == burstId {
                    members.append(photos[index])
                    index += 1
                }
                let best = members.first(where: \.isBestOfBurst)?.fileName ?? ""
                blocks.append("""
                <section class="burst">
                  <h2>Rafale \(burstId) · \(members.count) photos · meilleure : \(escape(best))</h2>
                  <div class="grid">\(members.map(card).joined())</div>
                </section>
                """)
            } else {
                var singles: [PhotoResult] = []
                while index < photos.count, photos[index].burstId == nil {
                    singles.append(photos[index])
                    index += 1
                }
                blocks.append("""
                <section class="singles">
                  <h2>Photos isolées · \(singles.count)</h2>
                  <div class="grid">\(singles.map(card).joined())</div>
                </section>
                """)
            }
        }

        let stats = report.stats
        let counts = Verdict.allCases.map { verdict in
            "<button data-filter=\"\(verdict.rawValue)\" class=\"chip \(verdict.rawValue)\">\(verdict.label) · \(stats.verdictCounts[verdict.rawValue] ?? 0)</button>"
        }.joined()
        let generated = report.generatedAt.formatted(.dateTime.locale(Locale(identifier: "fr_FR")))

        return """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Planche-contact LinkLens</title>
        <style>\(css)</style>
        </head>
        <body>
        <header>
          <h1>Planche-contact</h1>
          <p class="meta">\(escape(report.sourceFolder)) · \(stats.photoCount) photos · \(report.bursts.count) rafales · analysé le \(escape(generated))</p>
          <nav><button data-filter="all" class="chip active">Toutes · \(stats.photoCount)</button>\(counts)</nav>
        </header>
        <main>\(blocks.joined(separator: "\n"))</main>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    static func card(_ photo: PhotoResult) -> String {
        let reasons = photo.reasons.isEmpty
            ? "<li class=\"ok\">Aucun défaut détecté</li>"
            : photo.reasons.map { "<li class=\"\($0.verdict.rawValue)\">\(escape($0.message))</li>" }.joined()
        var scores = ["Netteté \(Int(photo.sharpness.rounded()))"]
        if let aesthetics = photo.aesthetics { scores.append("Esthétique \(String(format: "%.2f", aesthetics))") }
        if !photo.faces.isEmpty {
            let qualities = photo.faces.compactMap(\.captureQuality)
            let quality = qualities.isEmpty ? "" : " (qualité \(String(format: "%.2f", qualities.max() ?? 0)))"
            let eyes = photo.faces.compactMap(\.eyeOpenness).min().map { " · yeux \(String(format: "%.2f", $0))" } ?? ""
            scores.append("\(photo.faces.count) visage(s)\(quality)\(eyes)")
        }
        scores.append("Brûlés \(String(format: "%.1f", photo.highlightClipping * 100)) %")
        if let burstScore = photo.burstScore { scores.append("Score rafale \(String(format: "%.2f", burstScore))") }

        return """
        <figure class="card \(photo.verdict.rawValue)" data-verdict="\(photo.verdict.rawValue)">
          <a href="\(escape(photo.thumbnail))" target="_blank"><img loading="lazy" src="\(escape(photo.thumbnail))" alt="\(escape(photo.fileName))"></a>
          <figcaption>
            <div class="title"><span class="badge \(photo.verdict.rawValue)">\(photo.verdict.label)</span>\(photo.isBestOfBurst ? "<span class=\"star\" title=\"Meilleure de la rafale\">★</span>" : "")<span class="name">\(escape(photo.fileName))</span></div>
            <ul class="reasons">\(reasons)</ul>
            <p class="scores">\(scores.map(escape).joined(separator: " · "))</p>
          </figcaption>
        </figure>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let css = """
    :root { --bg:#f6f5f2; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e3e1dc;
            --keep:#2e9d55; --review:#d98a00; --reject:#d23c3c; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#161616; --card:#222; --text:#f2f2f2; --muted:#a0a0a5; --line:#333;
              --keep:#4cc274; --review:#f0a92e; --reject:#f06060; } }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:14px/1.4 -apple-system, system-ui, sans-serif; }
    header { position:sticky; top:0; z-index:1; background:var(--bg); padding:16px 24px 12px; border-bottom:1px solid var(--line); }
    h1 { margin:0; font-size:22px; }
    .meta { margin:4px 0 10px; color:var(--muted); overflow-wrap:anywhere; }
    nav { display:flex; flex-wrap:wrap; gap:8px; }
    .chip { border:1px solid var(--line); background:var(--card); color:var(--text); border-radius:999px; padding:5px 12px; font:inherit; cursor:pointer; }
    .chip.active { outline:2px solid var(--text); }
    .chip.keep { border-color:var(--keep); } .chip.review { border-color:var(--review); } .chip.reject { border-color:var(--reject); }
    main { padding:8px 24px 48px; }
    section { margin-top:20px; }
    section.burst { border:1px dashed var(--line); border-radius:12px; padding:12px; }
    h2 { font-size:15px; margin:0 0 10px; color:var(--muted); font-weight:600; }
    .grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(220px, 1fr)); gap:12px; }
    .card { margin:0; background:var(--card); border-radius:10px; overflow:hidden; border:3px solid var(--line); }
    .card.keep { border-color:var(--keep); } .card.review { border-color:var(--review); } .card.reject { border-color:var(--reject); }
    .card img { display:block; width:100%; aspect-ratio:2/3; object-fit:contain; background:#000; }
    figcaption { padding:8px 10px 10px; }
    .title { display:flex; align-items:center; gap:6px; font-weight:600; }
    .name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .badge { color:#fff; border-radius:4px; padding:1px 6px; font-size:12px; }
    .badge.keep { background:var(--keep); } .badge.review { background:var(--review); } .badge.reject { background:var(--reject); }
    .star { color:#e6b800; font-size:16px; }
    .reasons { margin:6px 0; padding-left:18px; }
    .reasons li.reject { color:var(--reject); } .reasons li.review { color:var(--review); } .reasons li.ok { color:var(--keep); }
    .scores { margin:0; color:var(--muted); font-size:12px; }
    .hidden { display:none; }
    @media (max-width: 520px) { header, main { padding-left:16px; padding-right:16px; } }
    """

    static let script = """
    document.querySelectorAll('[data-filter]').forEach(function (button) {
      button.addEventListener('click', function () {
        var filter = button.dataset.filter;
        document.querySelectorAll('[data-filter]').forEach(function (b) { b.classList.toggle('active', b === button); });
        document.querySelectorAll('.card').forEach(function (card) {
          card.classList.toggle('hidden', filter !== 'all' && card.dataset.verdict !== filter);
        });
        document.querySelectorAll('section').forEach(function (section) {
          section.classList.toggle('hidden', section.querySelectorAll('.card:not(.hidden)').length === 0);
        });
      });
    });
    """
}
