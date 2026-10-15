import SwiftUI

// MARK: - Region definitions

struct BirdRegion: Identifiable {
    let id: String          // matches metadata region field
    let label: String
    let polygon: [CGPoint]  // normalized 0–1 coords: x=(lon+180)/360, y=(90-lat)/180
}

private func pt(_ lon: Double, _ lat: Double) -> CGPoint {
    CGPoint(x: (lon + 180) / 360, y: (90 - lat) / 180)
}

let allRegions: [BirdRegion] = [
    BirdRegion(id: "eastern_na", label: "Eastern North America", polygon: [
        pt(-100,72), pt(-50,72), pt(-50,25), pt(-65,15), pt(-85,15), pt(-100,25)
    ]),
    BirdRegion(id: "western_na", label: "Western North America", polygon: [
        pt(-170,72), pt(-100,72), pt(-100,25), pt(-117,15), pt(-140,15), pt(-170,55)
    ]),
    BirdRegion(id: "central_america", label: "Central America & Caribbean", polygon: [
        pt(-100,25), pt(-55,25), pt(-55,8), pt(-82,8), pt(-100,20)
    ]),
    BirdRegion(id: "amazonia", label: "Amazonia", polygon: [
        pt(-80,5), pt(-44,5), pt(-44,-18), pt(-73,-18), pt(-80,0)
    ]),
    BirdRegion(id: "andes_pacific_sa", label: "Andes & Pacific South America", polygon: [
        pt(-82,12), pt(-60,12), pt(-60,-20), pt(-75,-20), pt(-82,5)
    ]),
    BirdRegion(id: "southern_sa", label: "Southern South America", polygon: [
        pt(-76,-20), pt(-44,-20), pt(-44,-58), pt(-68,-58), pt(-76,-40)
    ]),
    BirdRegion(id: "western_europe", label: "Western & Central Europe", polygon: [
        pt(-12,72), pt(25,72), pt(25,35), pt(-5,35), pt(-12,45)
    ]),
    BirdRegion(id: "eastern_europe", label: "Eastern Europe & Russia", polygon: [
        pt(25,80), pt(180,80), pt(180,45), pt(25,45)
    ]),
    BirdRegion(id: "west_central_africa", label: "West & Central Africa", polygon: [
        pt(-18,18), pt(30,18), pt(30,-5), pt(-5,-5), pt(-18,10)
    ]),
    BirdRegion(id: "east_africa", label: "East Africa", polygon: [
        pt(28,18), pt(52,18), pt(52,-12), pt(30,-12), pt(28,5)
    ]),
    BirdRegion(id: "southern_africa", label: "Southern Africa & Madagascar", polygon: [
        pt(10,-5), pt(52,-5), pt(52,-38), pt(20,-38), pt(10,-20)
    ]),
    BirdRegion(id: "mena", label: "Middle East & North Africa", polygon: [
        pt(-18,38), pt(65,38), pt(65,12), pt(40,12), pt(-18,15)
    ]),
    BirdRegion(id: "south_asia", label: "South Asia", polygon: [
        pt(60,38), pt(92,38), pt(92,5), pt(72,5), pt(60,20)
    ]),
    BirdRegion(id: "southeast_asia", label: "Southeast Asia", polygon: [
        pt(92,28), pt(142,28), pt(142,-10), pt(95,-10), pt(92,10)
    ]),
    BirdRegion(id: "east_asia", label: "East Asia", polygon: [
        pt(100,55), pt(148,55), pt(148,20), pt(100,20)
    ]),
    BirdRegion(id: "australia", label: "Australia", polygon: [
        pt(112,-10), pt(155,-10), pt(155,-45), pt(112,-45)
    ]),
    BirdRegion(id: "nz_pacific", label: "New Zealand & Pacific", polygon: [
        pt(155,-8), pt(220,-8), pt(220,-52), pt(165,-52), pt(155,-30)
    ]),
]

// MARK: - Map view

struct WorldMapView: View {
    @Binding var selected: Set<String>

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Color(white: 0.12)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Canvas { ctx, size in
                    for region in allRegions {
                        var path = Path()
                        let pts = region.polygon.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                        guard let first = pts.first else { continue }
                        path.move(to: first)
                        pts.dropFirst().forEach { path.addLine(to: $0) }
                        path.closeSubpath()
                        let isOn = selected.contains(region.id)
                        ctx.fill(path, with: .color(isOn ? Color.dawnYellow.opacity(0.75) : Color.white.opacity(0.18)))
                        ctx.stroke(path, with: .color(Color.black.opacity(0.5)), lineWidth: 0.8)
                    }
                }
                // Tap targets
                ForEach(allRegions) { region in
                    let pts = region.polygon.map { CGPoint(x: $0.x * w, y: $0.y * h) }
                    let center = centroid(of: pts)
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(center)
                        .onTapGesture { toggle(region.id) }
                }
            }
        }
        .aspectRatio(2, contentMode: .fit)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func centroid(of pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let x = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let y = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Full region select view

struct RegionSelectView: View {
    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap regions on the map or use the list. Leave all unchecked to draw from every region.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                WorldMapView(selected: $store.selectedRegions)
                    .padding(.horizontal, -4)

                Button(store.selectedRegions.isEmpty ? "All regions active" : "Clear selection") {
                    store.selectedRegions = []
                }
                .font(.caption)
                .foregroundColor(store.selectedRegions.isEmpty ? .secondary : .dawnYellow)
                .frame(maxWidth: .infinity, alignment: .trailing)

                Divider()

                ForEach(allRegions) { region in
                    let isOn = store.selectedRegions.contains(region.id)
                    let count = store.library.birds.filter { $0.region == region.id }.count
                    Button {
                        if isOn { store.selectedRegions.remove(region.id) }
                        else { store.selectedRegions.insert(region.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .foregroundColor(isOn ? .dawnYellow : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(region.label).font(.subheadline)
                                Text("\(count) birds").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(20)
        }
        .navigationTitle("Regions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
