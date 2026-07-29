import SwiftUI

/// A price line, drawn from the closes.
///
/// Hand-drawn with `Path` rather than using Swift Charts. Charts would bring
/// axes, gridlines and a legend to a shape that is 40 points tall and has no
/// room for any of them — the job here is "did it go up or down, and how
/// bumpily", and a bare line answers it better.
struct Sparkline: View {

    let points: [Double]
    let isUp: Bool

    var body: some View {
        GeometryReader { geometry in
            let shape = path(in: geometry.size)

            ZStack {
                // The fill under the line is what makes the direction readable
                // at a glance, before the eye finds the percentage.
                shape.filled(in: geometry.size)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                shape
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8,
                                                     lineCap: .round,
                                                     lineJoin: .round))
            }
        }
    }

    private var tint: Color {
        isUp ? Color(red: 0.243, green: 0.706, blue: 0.478)
             : Color(red: 0.878, green: 0.318, blue: 0.278)
    }

    private func path(in size: CGSize) -> SparkPath {
        SparkPath(points: points)
    }
}

/// The geometry, separated so the line and its fill cannot disagree.
struct SparkPath: Shape {

    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = coordinates(in: rect).first else { return path }
        path.move(to: first)
        for point in coordinates(in: rect).dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    /// The same line, closed along the bottom edge.
    func filled(in size: CGSize) -> Path {
        let rect = CGRect(origin: .zero, size: size)
        var path = Path()
        let points = coordinates(in: rect)
        guard let first = points.first, let last = points.last else { return path }

        path.move(to: CGPoint(x: first.x, y: rect.maxY))
        path.addLine(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func coordinates(in rect: CGRect) -> [CGPoint] {
        guard points.count > 1 else { return [] }

        let lowest = points.min() ?? 0
        let highest = points.max() ?? 1
        // A flat line has zero range, and dividing by it puts the whole series
        // at infinity. Centring it is the honest rendering of "nothing moved".
        let range = highest - lowest
        let step = rect.width / CGFloat(points.count - 1)

        return points.enumerated().map { index, value in
            let normalised = range == 0 ? 0.5 : (value - lowest) / range
            return CGPoint(x: rect.minX + CGFloat(index) * step,
                           y: rect.maxY - CGFloat(normalised) * rect.height)
        }
    }
}

/// One instrument: price, move, and the shape of the day.
struct MarketCard: View {

    let series: MarketSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(series.symbol)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: series.isUp ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(tint)
            }

            Text(series.formattedLast)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(series.formattedChange)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)

            Sparkline(points: series.points, isUp: series.isUp)
                .frame(height: 34)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tint: Color {
        series.isUp ? Color(red: 0.243, green: 0.706, blue: 0.478)
                    : Color(red: 0.878, green: 0.318, blue: 0.278)
    }
}

/// Both cards side by side, with the provenance line underneath.
struct MarketStrip: View {

    @EnvironmentObject private var markets: MarketStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if markets.series.isEmpty {
                if markets.phase.isBusy {
                    HStack {
                        ProgressView()
                        Text("Loading prices…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else if let message = markets.phase.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(markets.series, id: \.symbol) { series in
                        MarketCard(series: series)
                    }
                }

                // Unofficial public endpoints, so it is only fair to name them.
                Text(markets.series.map(\.provider).joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
