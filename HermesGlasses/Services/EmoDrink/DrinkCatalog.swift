//
// DrinkCatalog.swift
//
// The drinks the recommender chooses from: a bundled JSON of public Asahi
// Group soft drinks, each tagged by what it is for. Adding a drink is a JSON
// edit; the recommender reads only the fields here. Foundation only;
// tested in tests/emodrink-catalog.
//

import Foundation

enum DrinkFunction: String, Codable, CaseIterable, Equatable {
    case hydrate, calm, energise, recover, refresh

    var label: String {
        switch self {
        case .hydrate: return "Hydrate"
        case .calm: return "Calm"
        case .energise: return "Energise"
        case .recover: return "Recover"
        case .refresh: return "Refresh"
        }
    }
}

enum SugarLevel: String, Codable, Equatable {
    case none, low, regular
}

enum ServedTemperature: String, Codable, Equatable {
    case cold, hot, either
}

struct Drink: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let nameJa: String
    let kind: String
    /// In priority order: the first function is what the drink is mostly for.
    let functions: [DrinkFunction]
    let caffeineMg: Int
    let sugar: SugarLevel
    let served: ServedTemperature

    enum CodingKeys: String, CodingKey {
        case id, name, kind, functions, sugar, served
        case nameJa = "name_ja"
        case caffeineMg = "caffeine_mg"
    }
}

struct DrinkCatalog: Codable, Equatable {
    let drinks: [Drink]

    static let bundledResourceName = "asahi-drinks"
    /// Where the same file lives in the repo, for the swiftc tests.
    static let repoPath = "HermesGlasses/Resources/EmoDrink/asahi-drinks.json"

    enum CatalogError: LocalizedError, Equatable {
        case empty
        case duplicateID(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The drink catalogue is empty."
            case .duplicateID(let id): return "Duplicate drink id: \(id)"
            }
        }
    }

    static func decode(_ data: Data) throws -> DrinkCatalog {
        let catalog = try JSONDecoder().decode(DrinkCatalog.self, from: data)
        guard !catalog.drinks.isEmpty else { throw CatalogError.empty }
        var seen = Set<String>()
        for drink in catalog.drinks {
            guard seen.insert(drink.id).inserted else { throw CatalogError.duplicateID(drink.id) }
        }
        return catalog
    }

    /// The copy shipped in the app bundle. Nil when the resource is missing
    /// or invalid; the caller decides how loudly to fail.
    static func bundled(bundle: Bundle = .main) -> DrinkCatalog? {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    func drink(id: String) -> Drink? { drinks.first { $0.id == id } }
}
