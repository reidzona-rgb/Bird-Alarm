import SwiftUI

/// The Active Alarm Display: illustration, common name, fact card, dismiss.
struct WakingView: View {
    @EnvironmentObject private var store: AlarmStore
    let bird: Bird

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                artwork
                    .frame(width: geo.size.width, height: geo.size.height * 0.36)
                    .clipped()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bird.name)
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .minimumScaleFactor(0.6)
                                .lineLimit(2)
                            if let latin = bird.scientificName {
                                Text(latin)
                                    .font(.title3.italic())
                                    .foregroundColor(.dawnYellow)
                            }
                        }

                        factCard

                        if let credits = creditLine {
                            Text(credits)
                                .font(.caption2)
                                .foregroundColor(Color(white: 0.6))
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom) {
            Button(action: store.dismiss) {
                Text(store.isPreview ? "End Preview" : "Dismiss Alarm")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                    .background(Color.dawnYellow)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.black)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = bird.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            // Shown until the asset folder has an image.
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.2), Color.dawnYellow],
                               startPoint: .bottom, endPoint: .top)
                Image(systemName: "bird.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.black)
                    .padding(60)
            }
        }
    }

    private var factCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(bird.facts.prefix(3).enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(Color.dawnYellow)
                        .frame(width: 8, height: 8)
                        .padding(.top, 7)
                    Text(fact)
                        .font(.body)
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardGray)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var creditLine: String? {
        let parts = [bird.audioCredit.map { "Audio: \($0)" }, bird.imageCredit.map { "Photo: \($0)" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
