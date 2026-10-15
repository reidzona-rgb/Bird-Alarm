import SwiftUI

// MARK: - Region data

struct BirdRegion: Identifiable {
    let id: String
    let label: String
    // Placement of the "Region_<id>" highlight image, normalised to MapBase (from tools/render_map.py frames.json)
    let frame: CGRect
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

let allRegions: [BirdRegion] = [
    BirdRegion(id: "eastern_na",          label: "Eastern North America",         frame: rect(0.157333, 0.010978, 0.313000, 0.589321)),
    BirdRegion(id: "western_na",          label: "Western North America",         frame: rect(0.000333, 0.133733, 0.999667, 0.473054)),
    BirdRegion(id: "central_america",     label: "Central America & Caribbean",   frame: rect(0.169000, 0.554890, 0.168000, 0.127745)),
    BirdRegion(id: "amazonia",            label: "Amazonia",                      frame: rect(0.242333, 0.633234, 0.179333, 0.221557)),
    BirdRegion(id: "andes_pacific_sa",    label: "Andes & Pacific South America", frame: rect(0.193667, 0.633234, 0.148667, 0.353792)),
    BirdRegion(id: "southern_sa",         label: "Southern South America",        frame: rect(0.293333, 0.780938, 0.135667, 0.219062)),
    BirdRegion(id: "western_europe",      label: "Western & Central Europe",      frame: rect(0.411000, 0.099800, 0.184333, 0.486028)),
    BirdRegion(id: "eastern_europe",      label: "Eastern Europe & Russia",       frame: rect(0.000000, 0.069860, 1.000000, 0.479541)),
    BirdRegion(id: "west_central_africa", label: "West & Central Africa",         frame: rect(0.427333, 0.581337, 0.161667, 0.307884)),
    BirdRegion(id: "east_africa",         label: "East Africa",                   frame: rect(0.558333, 0.604291, 0.086333, 0.150200)),
    BirdRegion(id: "southern_africa",     label: "Southern Africa & Madagascar",  frame: rect(0.530333, 0.715070, 0.148000, 0.212076)),
    BirdRegion(id: "mena",                label: "Middle East & North Africa",    frame: rect(0.450333, 0.505988, 0.259667, 0.148703)),
    BirdRegion(id: "south_asia",          label: "South Asia",                    frame: rect(0.667000, 0.532934, 0.105333, 0.203593)),
    BirdRegion(id: "southeast_asia",      label: "Southeast Asia",                frame: rect(0.754000, 0.575349, 0.181333, 0.181138)),
    BirdRegion(id: "east_asia",           label: "East Asia",                     frame: rect(0.702333, 0.434631, 0.227333, 0.204591)),
    BirdRegion(id: "australia",           label: "Australia",                     frame: rect(0.811667, 0.737525, 0.132333, 0.241018)),
    BirdRegion(id: "nz_pacific",          label: "New Zealand & Pacific",         frame: rect(0.000000, 0.576846, 1.000000, 0.386727)),
]

// MARK: - Map view (display only)

private let mapAspect: CGFloat = 3000.0 / 2004.0

struct WorldMapView: View {
    let selected: Set<String>

    var body: some View {
        Image("MapBase")
            .resizable()
            .interpolation(.high)
            .aspectRatio(mapAspect, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    ForEach(allRegions) { region in
                        if selected.contains(region.id) {
                            Image("Region_\(region.id)")
                                .resizable()
                                .interpolation(.high)
                                .frame(width: region.frame.width * w, height: region.frame.height * h)
                                .position(x: region.frame.midX * w, y: region.frame.midY * h)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selected)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Region select view

struct RegionSelectView: View {
    @EnvironmentObject private var store: AlarmStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                WorldMapView(selected: store.selectedRegions)

                HStack {
                    Text(store.selectedRegions.isEmpty ? "All regions active" : "\(store.selectedRegions.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !store.selectedRegions.isEmpty {
                        Button("Clear selection") { store.selectedRegions = [] }
                            .font(.caption)
                            .foregroundColor(.dawnYellow)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Check the regions to draw birds from. Leave all unchecked to use every region.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)

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
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(Color.black)
        .navigationTitle("Regions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
