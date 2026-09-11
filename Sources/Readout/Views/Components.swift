import SwiftUI

/// Building blocks for the panel.
///
/// The look follows the system's own control modules: rounded translucent
/// cards, a single accent colour, and numbers large enough to read at a
/// glance. Colour is reserved for values that have crossed a threshold.

/// Standard easing for the bars, so every meter in the panel moves at the same
/// rate.
///
/// Only geometry is animated. Animating the *numbers* as well — a
/// `contentTransition(.numericText())` on each row — meant every visible label
/// re-rendered its glyphs on every frame for the duration, and with a reading
/// arriving each second the app sat at 60-80% CPU doing nothing but redrawing
/// text. A stack sample was almost entirely `CA::Transaction::commit` into
/// glyph rasterisation. Rows now cut straight to the new value.
extension Animation {
    static let reading = Animation.smooth(duration: 0.45)
}

/// A rounded module, the way Control Center groups related controls.
struct Card<Content: View>: View {
    var title: String
    var symbol: String?
    var value: String?
    var valueColor: Color = .primary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                }
            }
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }
}

/// A single-value bar.
struct MeterBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 8

    var body: some View {
        // Scaling a rectangle inside a capsule-clipped track avoids a
        // GeometryReader per bar: the panel has a dozen of them and they all
        // re-measure on every sample.
        Capsule()
            .fill(Color.primary.opacity(0.09))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(color.gradient)
                    .scaleEffect(x: min(1, max(0, fraction)), anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: height)
            .animation(.reading, value: fraction)
    }
}

/// A bar split into parts, used for the memory breakdown.
struct StackedBar: View {
    struct Segment {
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                // Keyed by position. The card builds its segments afresh with
                // every sample, and when each carried a new UUID, SwiftUI tore
                // down and re-created every part of the bar each time instead
                // of resizing the ones it had.
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(segments[index].color)
                        .frame(width: width(for: segments[index].value, in: proxy.size.width))
                }
                Rectangle().fill(Color.primary.opacity(0.09))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.reading, value: total)
    }

    private func width(for value: Double, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(0, CGFloat(value / total) * available)
    }
}

/// Colour swatch, name and figure, matching the stacked bar's parts.
struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
    }
}

/// History graph, drawn as a smooth curve rather than a polyline.
struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    /// Fixed top of the scale; omit to scale to whatever the window contains.
    var ceiling: Double?

    var body: some View {
        GeometryReader { proxy in
            let points = points(in: proxy.size)
            ZStack {
                if points.count > 1 {
                    curve(through: points, closingAt: proxy.size.height)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.35), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    curve(through: points, closingAt: nil)
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                        )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let scale = max(ceiling ?? 1, values.max() ?? 1, 0.0001)
        let step = size.width / CGFloat(values.count - 1)
        // A little headroom keeps a pegged value from sitting on the border.
        let usable = size.height - 3
        return values.enumerated().map { index, value in
            CGPoint(
                x: CGFloat(index) * step,
                y: 2 + usable * (1 - CGFloat(min(value / scale, 1)))
            )
        }
    }

    /// Rounds the corners between samples so the line reads as a trend rather
    /// than a sequence of ticks.
    private func curve(through points: [CGPoint], closingAt bottom: CGFloat?) -> Path {
        Path { path in
            path.move(to: points[0])
            for index in 1 ..< points.count {
                let previous = points[index - 1]
                let current = points[index]
                let midX = (previous.x + current.x) / 2
                path.addCurve(
                    to: current,
                    control1: CGPoint(x: midX, y: previous.y),
                    control2: CGPoint(x: midX, y: current.y)
                )
            }
            if let bottom {
                path.addLine(to: CGPoint(x: points[points.count - 1].x, y: bottom))
                path.addLine(to: CGPoint(x: points[0].x, y: bottom))
                path.closeSubpath()
            }
        }
    }
}

/// One bar per logical core, with the performance and efficiency runs split.
struct CoreGrid: View {
    let cores: [Double]
    let performanceCores: Int

    // Deliberately unanimated: a dozen bars all easing at once is a dozen
    // layer commits per frame, and per-core load is spiky enough that the
    // easing reads as lag rather than motion.
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, load in
                if index == performanceCores, performanceCores > 0, index < cores.count {
                    Capsule()
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 2)
                }
                bar(load: load, isEfficiency: index >= performanceCores && performanceCores > 0)
            }
        }
        .frame(height: 22)
    }

    private func bar(load: Double, isEfficiency: Bool) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(
                        (isEfficiency ? Color.accentColor.opacity(0.5) : Color.accentColor)
                            .gradient
                    )
                    .frame(height: max(2.5, proxy.size.height * min(1, max(0, load))))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.primary.opacity(0.09))
        )
        .frame(maxWidth: .infinity)
    }
}

/// Label on the left, figure on the right.
struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
}
