import Foundation
import UIKit

/// One slot in the Chorus Deck. Backed by a folder in assets/birds/.
struct Bird: Identifiable, Equatable {
    let id: String              // folder name, e.g. "01_song_sparrow"
    let name: String
    let scientificName: String?
    let facts: [String]
    let audioCredit: String?
    let imageCredit: String?
    let folder: URL
    let region: String          // e.g. "eastern_na"
    let harmonicScore: Int      // 1–10; higher = richer song, biases the shuffle

    static func == (lhs: Bird, rhs: Bird) -> Bool { lhs.id == rhs.id }

    var audioURL: URL? { firstExisting(["audio.mp3", "audio.wav", "audio.m4a"]) }
    var imageURL: URL? { firstExisting(["image.png", "image.jpg", "image.jpeg"]) }

    var image: UIImage? {
        guard let url = imageURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private func firstExisting(_ names: [String]) -> URL? {
        for name in names {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

private struct BirdMetadata: Decodable {
    let name: String
    let scientificName: String?
    let facts: [String]
    let audioCredit: String?
    let imageCredit: String?
    let region: String?
    let harmonicScore: Int?
}

final class BirdLibrary {
    static let shared = BirdLibrary()

    let birds: [Bird]

    private(set) lazy var playable: [Bird] = birds.filter { $0.audioURL != nil }

    /// All distinct region IDs present in the library.
    var regions: [String] { Array(Set(birds.map { $0.region })).sorted() }

    private init() {
        var loaded: [Bird] = []
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if let root = Bundle.main.resourceURL?.appendingPathComponent("assets/birds"),
           let folders = try? FileManager.default.contentsOfDirectory(
               at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let metaURL = folder.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let meta = try? decoder.decode(BirdMetadata.self, from: data) else { continue }
                loaded.append(Bird(
                    id: folder.lastPathComponent,
                    name: meta.name,
                    scientificName: meta.scientificName,
                    facts: meta.facts,
                    audioCredit: meta.audioCredit,
                    imageCredit: meta.imageCredit,
                    folder: folder,
                    region: meta.region ?? "eastern_na",
                    harmonicScore: meta.harmonicScore ?? 6))
            }
        }
        birds = loaded
    }

    func bird(withID id: String?) -> Bird? {
        guard let id else { return nil }
        return birds.first { $0.id == id }
    }
}
