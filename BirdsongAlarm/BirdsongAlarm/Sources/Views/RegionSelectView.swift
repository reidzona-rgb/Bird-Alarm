import SwiftUI

// MARK: - Region data

struct BirdRegion: Identifiable {
    let id: String
    let label: String        // full name for the list
    let shortLabel: String   // abbreviated for the map overlay
    let polygon: [CGPoint]   // normalised Mercator 0–1 coords
}

// Mercator projection, clamped ±79.9°, normalised so 80°N→y=0, 80°S→y=1
private let _mMax: Double = {
    let phi80 = 80.0 * Double.pi / 180.0
    return log(tan(Double.pi / 4.0 + phi80 / 2.0))
}()

private func pt(_ lon: Double, _ lat: Double) -> CGPoint {
    let clamped = min(79.9, max(-79.9, lat))
    let phi = clamped * Double.pi / 180.0
    let x = (lon + 180.0) / 360.0
    let y = (1.0 - log(tan(Double.pi / 4.0 + phi / 2.0)) / _mMax) / 2.0
    return CGPoint(x: x, y: y)
}

// MARK: - Region definitions

let allRegions: [BirdRegion] = [

    BirdRegion(id: "eastern_na", label: "Eastern North America", shortLabel: "E. N. America",
    polygon: [
        pt(-100,70), pt(-88,74), pt(-78,73), pt(-65,60),
        pt(-52,47),  pt(-60,47), pt(-66,44), pt(-70,42),
        pt(-74,40),  pt(-76,34), pt(-80,32), pt(-81,25),
        pt(-90,25),  pt(-97,25), pt(-100,30),pt(-100,70)
    ]),

    BirdRegion(id: "western_na", label: "Western North America", shortLabel: "W. N. America",
    polygon: [
        pt(-168,66), pt(-161,72), pt(-148,70),pt(-140,70),
        pt(-100,70), pt(-100,30), pt(-97,25), pt(-106,22),
        pt(-117,22), pt(-117,32), pt(-122,37),pt(-124,49),
        pt(-130,54), pt(-141,59), pt(-153,59),pt(-168,66)
    ]),

    BirdRegion(id: "central_america", label: "Central America & Caribbean", shortLabel: "C. America\n& Caribbean",
    polygon: [
        pt(-97,25),  pt(-81,25),  pt(-80,22), pt(-83,10),
        pt(-77,7),   pt(-68,12),  pt(-60,10), pt(-60,24),
        pt(-73,18),  pt(-84,22),  pt(-87,16), pt(-90,21),
        pt(-97,25)
    ]),

    BirdRegion(id: "amazonia", label: "Amazonia", shortLabel: "Amazonia",
    polygon: [
        pt(-80,8),   pt(-65,12),  pt(-60,12), pt(-51,5),
        pt(-44,5),   pt(-44,-15), pt(-50,-20),pt(-57,-22),
        pt(-60,-20), pt(-73,-18), pt(-80,0),  pt(-80,8)
    ]),

    BirdRegion(id: "andes_pacific_sa", label: "Andes & Pacific South America", shortLabel: "Andes &\nPacific SA",
    polygon: [
        pt(-82,10),  pt(-77,7),   pt(-80,0),  pt(-73,-18),
        pt(-68,-22), pt(-70,-35), pt(-72,-42),pt(-76,-35),
        pt(-80,-5),  pt(-82,10)
    ]),

    BirdRegion(id: "southern_sa", label: "Southern South America", shortLabel: "S. South\nAmerica",
    polygon: [
        pt(-60,-20), pt(-57,-22), pt(-44,-20), pt(-41,-22),
        pt(-34,-7),  pt(-40,-20), pt(-44,-23), pt(-52,-33),
        pt(-58,-35), pt(-65,-55), pt(-68,-55), pt(-70,-50),
        pt(-70,-35), pt(-68,-22), pt(-60,-20)
    ]),

    BirdRegion(id: "western_europe", label: "Western & Central Europe", shortLabel: "W. Europe",
    polygon: [
        pt(-12,72),  pt(8,72),   pt(16,70),  pt(28,72),
        pt(30,60),   pt(28,55),  pt(22,55),  pt(18,45),
        pt(14,45),   pt(8,44),   pt(3,43),   pt(-2,44),
        pt(-9,38),   pt(-9,43),  pt(0,51),   pt(-5,58),
        pt(-12,62),  pt(-12,72)
    ]),

    BirdRegion(id: "eastern_europe", label: "Eastern Europe & Russia", shortLabel: "E. Europe\n& Russia",
    polygon: [
        pt(28,72),   pt(180,73), pt(180,45), pt(135,35),
        pt(120,40),  pt(80,45),  pt(60,44),  pt(50,45),
        pt(30,50),   pt(23,55),  pt(30,60),  pt(28,72)
    ]),

    BirdRegion(id: "west_central_africa", label: "West & Central Africa", shortLabel: "W/C Africa",
    polygon: [
        pt(-18,20),  pt(0,20),   pt(15,24),  pt(30,22),
        pt(35,15),   pt(30,5),   pt(28,-5),
        pt(12,-5),   pt(0,0),    pt(-5,5),
        pt(-18,15),  pt(-18,20)
    ]),

    BirdRegion(id: "east_africa", label: "East Africa", shortLabel: "E. Africa",
    polygon: [
        pt(30,22),   pt(38,22),  pt(45,12),  pt(51,12),
        pt(44,-12),  pt(36,-12), pt(30,-5),  pt(28,5),
        pt(35,15),   pt(30,22)
    ]),

    BirdRegion(id: "southern_africa", label: "Southern Africa & Madagascar", shortLabel: "S. Africa &\nMadagascar",
    polygon: [
        pt(10,-5),   pt(28,-5),  pt(36,-12), pt(40,-10),
        pt(44,-12),  pt(44,-26), pt(36,-35), pt(26,-35),
        pt(17,-35),  pt(16,-25), pt(12,-18), pt(10,-5)
    ]),

    BirdRegion(id: "mena", label: "Middle East & North Africa", shortLabel: "MENA",
    polygon: [
        pt(-18,38),  pt(0,38),   pt(20,38),  pt(36,42),
        pt(42,42),   pt(65,38),  pt(65,12),
        pt(44,12),   pt(37,15),  pt(32,22),
        pt(25,30),   pt(13,33),  pt(-5,36),
        pt(-10,35),  pt(-18,38)
    ]),

    BirdRegion(id: "south_asia", label: "South Asia", shortLabel: "South Asia",
    polygon: [
        pt(60,38),   pt(72,38),  pt(80,38),  pt(92,32),
        pt(92,22),   pt(85,12),  pt(80,8),
        pt(72,8),    pt(66,20),  pt(60,22),  pt(60,38)
    ]),

    BirdRegion(id: "southeast_asia", label: "Southeast Asia", shortLabel: "SE Asia",
    polygon: [
        pt(92,28),   pt(100,28), pt(120,30), pt(135,10),
        pt(142,5),   pt(130,-8), pt(128,-8),
        pt(106,-8),  pt(95,-6),  pt(95,5),
        pt(92,22),   pt(92,28)
    ]),

    BirdRegion(id: "east_asia", label: "East Asia", shortLabel: "East Asia",
    polygon: [
        pt(100,55),  pt(135,55), pt(142,55), pt(148,43),
        pt(142,35),  pt(135,34), pt(125,34), pt(122,30),
        pt(120,22),  pt(110,20), pt(100,22),
        pt(100,45),  pt(100,55)
    ]),

    BirdRegion(id: "australia", label: "Australia", shortLabel: "Australia",
    polygon: [
        pt(113,-22), pt(114,-26),pt(115,-34),pt(118,-35),
        pt(129,-35), pt(138,-38),pt(149,-38),pt(152,-28),
        pt(150,-22), pt(145,-15),pt(136,-12),pt(130,-12),
        pt(122,-18), pt(113,-22)
    ]),

    BirdRegion(id: "nz_pacific", label: "New Zealand & Pacific", shortLabel: "NZ &\nPacific",
    polygon: [
        pt(155,-8),  pt(180,-8), pt(180,-52),
        pt(166,-46), pt(168,-36),pt(174,-34),
        pt(178,-37), pt(170,-30),pt(155,-15),
        pt(155,-8)
    ]),
]

// MARK: - Map view

struct WorldMapView: View {
    @Binding var selected: Set<String>

    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @GestureState private var liveZoom: CGFloat = 1.0
    @GestureState private var livePan: CGSize = .zero

    private var effectiveZoom: CGFloat {
        min(max(zoom * liveZoom, 1.0), 6.0)
    }
    private var effectivePan: CGSize {
        CGSize(width: pan.width + livePan.width,
               height: pan.height + livePan.height)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Ocean
                Color(red: 0.44, green: 0.73, blue: 0.87)

                Canvas { ctx, size in
                    // Graticule
                    var grid = Path()
                    for lonStep in 0...12 {
                        let lon = -180.0 + Double(lonStep) * 30.0
                        let a = pt(lon, 79.9)
                        let b = pt(lon, -79.9)
                        grid.move(to: CGPoint(x: a.x * size.width, y: a.y * size.height))
                        grid.addLine(to: CGPoint(x: b.x * size.width, y: b.y * size.height))
                    }
                    for latStep in 0...4 {
                        let lat = -60.0 + Double(latStep) * 30.0
                        let a = pt(-180.0, lat)
                        let b = pt(180.0, lat)
                        grid.move(to: CGPoint(x: a.x * size.width, y: a.y * size.height))
                        grid.addLine(to: CGPoint(x: b.x * size.width, y: b.y * size.height))
                    }
                    ctx.stroke(grid, with: .color(.white.opacity(0.15)), lineWidth: 0.4)

                    // Region fills + outlines
                    for region in allRegions {
                        let pts = region.polygon.map {
                            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
                        }
                        var path = Path()
                        guard let first = pts.first else { continue }
                        path.move(to: first)
                        for p in pts.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                        let isOn = selected.contains(region.id)
                        let fill = isOn
                            ? Color(red: 1.0, green: 0.82, blue: 0.22).opacity(0.9)
                            : Color.white.opacity(0.88)
                        ctx.fill(path, with: .color(fill))
                        ctx.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 0.7)
                    }
                }

                // Tap targets + labels
                ForEach(allRegions) { region in
                    let pts = region.polygon.map {
                        CGPoint(x: $0.x * w, y: $0.y * h)
                    }
                    let cx = pts.map(\.x).reduce(0.0, +) / CGFloat(pts.count)
                    let cy = pts.map(\.y).reduce(0.0, +) / CGFloat(pts.count)
                    let isOn = selected.contains(region.id)

                    Color.clear
                        .frame(width: 70, height: 50)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleRegion(region.id) }
                        .overlay(
                            Text(region.shortLabel)
                                .font(.system(size: 6.5, weight: .bold))
                                .foregroundColor(isOn ? Color(white: 0.08) : Color(white: 0.15))
                                .shadow(color: .white.opacity(0.7), radius: 1.0, x: 0, y: 0)
                                .multilineTextAlignment(.center)
                                .allowsHitTesting(false)
                        )
                        .position(x: cx, y: cy)
                }
            }
        }
        .aspectRatio(2.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .scaleEffect(effectiveZoom)
        .offset(effectivePan)
        .gesture(zoomPanGesture)
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                zoom = 1.0
                pan = .zero
            }
        }
    }

    // Pinch-to-zoom + drag-to-pan as a simultaneous gesture pair
    private var zoomPanGesture: some Gesture {
        MagnifyGesture()
            .updating($liveZoom) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                zoom = min(max(zoom * value.magnification, 1.0), 6.0)
            }
            .simultaneously(with:
                DragGesture(minimumDistance: 4)
                    .updating($livePan) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        pan.width  += value.translation.width
                        pan.height += value.translation.height
                    }
            )
    }

    private func toggleRegion(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

// MARK: - Region select view

struct RegionSelectView: View {
    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap a region to select it. Pinch to zoom · drag to pan · double-tap to reset. Leave all unchecked to draw from every region.")
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
                        else    { store.selectedRegions.insert(region.id) }
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
