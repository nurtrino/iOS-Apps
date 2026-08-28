import SwiftUI

/// The small shared pieces every screen leans on.

struct LoadingView: View {
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Impact {
    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        case .holiday: return .blue
        }
    }
}

/// The impact dot every calendar row carries.
struct ImpactDot: View {
    let impact: Impact

    var body: some View {
        Circle()
            .fill(impact.color)
            .frame(width: 8, height: 8)
    }
}

/// Numbers formatted with the precision the magnitude deserves: indices with
/// no decimals, oil with two, FX with four.
enum PriceFormat {
    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let digits: Int
        let magnitude = abs(value)
        if magnitude >= 1000 { digits = 0 } else if magnitude >= 10 { digits = 2 } else { digits = 4 }
        formatter.maximumFractionDigits = digits
        formatter.minimumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    static func formatChange(_ percent: Double) -> String {
        String(format: "%@%.2f%%", percent >= 0 ? "+" : "−", abs(percent))
    }
}
