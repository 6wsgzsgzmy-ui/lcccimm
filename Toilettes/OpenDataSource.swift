import CoreLocation

/// Jeux de données officiels publiés sur des portails OpenDataSoft.
/// Pour ajouter une source : un `case`, ses propriétés (`name`, `host`, `datasetID`) et son mapping dans `toilet(from:lat:lon:)`.
enum OpenDataSource: CaseIterable {
    case paris        // Ville de Paris (jeu officiel)
    case regionIDF    // Région Île-de-France : jeu consolidé (Paris, RATP, OSM, données remontées par les communes)

    /// Mention d'attribution affichée dans la fiche.
    var name: String {
        switch self {
        case .paris: "Ville de Paris (open data, ODbL)"
        case .regionIDF: "Région Île-de-France (open data, ODbL)"
        }
    }

    var host: String {
        switch self {
        case .paris: "https://opendata.paris.fr"
        case .regionIDF: "https://data.iledefrance.fr"
        }
    }

    var datasetID: String {
        switch self {
        case .paris: "sanisettesparis"
        case .regionIDF: "toilettes-publiques-en-ile-de-france"
        }
    }

    /// Champ géographique, utilisé seulement par l'API v2.1 (repli si l'API v1 est indisponible).
    var geoField: String { "geo_point_2d" }

    /// Un jeu consolidé ne sert qu'à combler les trous : il passe après OpenStreetMap en cas de doublon.
    var isConsolidated: Bool { self == .regionIDF }

    // MARK: - Conversion en Toilet (lecture tolérante : champs optionnels)

    func toilet(from f: [String: Any], lat: Double, lon: Double) -> Toilet? {
        func text(_ keys: [String]) -> String? {
            for k in keys { if let s = f[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        func yes(_ keys: [String]) -> Bool {
            for k in keys {
                if let b = f[k] as? Bool { return b }
                if let s = (f[k] as? String)?.lowercased() { return ["oui", "yes", "true", "1"].contains(s) }
            }
            return false
        }

        switch self {
        case .paris:
            if (f["statut"] as? String)?.lowercased().contains("ferm") == true { return nil }
            let type = (f["type"] as? String) ?? ""
            var tags: [String: String] = ["name": type.isEmpty ? "Sanisette" : type.capitalized]
            // Les « Lavatory » sont les toilettes à accès payant (cf. description du jeu de données).
            tags["fee"] = type.lowercased().contains("lavatory") ? "yes" : "no"
            if yes(["acces_pmr"]) { tags["wheelchair"] = "yes" }
            if yes(["relais_bebe"]) { tags["changing_table"] = "yes" }
            if let h = text(["horaire"]) { tags["opening_hours"] = h }
            let addr = [text(["adresse"]), text(["arrondissement"])].compactMap { $0 }.joined(separator: ", ")
            if !addr.isEmpty { tags["address"] = addr }
            return Toilet(id: "paris-\(lat)-\(lon)", latitude: lat, longitude: lon, tags: tags, source: name)

        case .regionIDF:
            var tags: [String: String] = ["name": text(["nom", "name", "libelle"]) ?? "Toilettes publiques"]
            if yes(["acces_pmr", "pmr", "wheelchair"]) { tags["wheelchair"] = "yes" }
            if let h = text(["horaires", "horaire", "opening_hours"]) { tags["opening_hours"] = h }
            let addr = [text(["adresse", "address"]), text(["commune", "ville"])].compactMap { $0 }.joined(separator: ", ")
            if !addr.isEmpty { tags["address"] = addr }
            return Toilet(id: "idf-\(lat)-\(lon)", latitude: lat, longitude: lon, tags: tags, source: name)
        }
    }

    // MARK: - Récupération

    private struct Row { let fields: [String: Any]; let lat: Double; let lon: Double }

    func fetch(around c: CLLocationCoordinate2D, radius: Int) async -> [Toilet] {
        // 1) API v1 : filtre géographique indépendant du nom du champ. 2) Repli sur l'API v2.1.
        let rows: [Row]
        if let v1 = await pages(url: { v1URL(c, radius, start: $0) }, parse: parseV1) {
            rows = v1
        } else {
            rows = await pages(url: { v2URL(c, radius, offset: $0) }, parse: parseV2) ?? []
        }
        return rows.compactMap { toilet(from: $0.fields, lat: $0.lat, lon: $0.lon) }
    }

    /// Interroge les sources officielles (ou consolidées) ; ne lève jamais d'erreur : une source en panne est ignorée.
    static func fetchAll(consolidated: Bool, around c: CLLocationCoordinate2D, radius: Int) async -> [Toilet] {
        var all: [Toilet] = []
        for source in allCases where source.isConsolidated == consolidated {
            all += await source.fetch(around: c, radius: radius)
        }
        return all
    }

    private func pages(url: (Int) -> URL?, parse: ([String: Any]) -> ([Row], Int)?) async -> [Row]? {
        var all: [Row] = []
        for page in 0..<5 {   // 5 pages de 100 résultats maximum
            guard let url = url(page * 100) else { return page == 0 ? nil : all }
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let (rows, raw) = parse(json) else { return page == 0 ? nil : all }
            all += rows
            if raw < 100 { break }
        }
        return all
    }

    private func v1URL(_ c: CLLocationCoordinate2D, _ radius: Int, start: Int) -> URL? {
        var comps = URLComponents(string: host + "/api/records/1.0/search/")
        comps?.queryItems = [
            URLQueryItem(name: "dataset", value: datasetID),
            URLQueryItem(name: "rows", value: "100"),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "geofilter.distance", value: "\(c.latitude),\(c.longitude),\(radius)")
        ]
        return comps?.url
    }

    private func v2URL(_ c: CLLocationCoordinate2D, _ radius: Int, offset: Int) -> URL? {
        var comps = URLComponents(string: host + "/api/explore/v2.1/catalog/datasets/\(datasetID)/records")
        comps?.queryItems = [
            URLQueryItem(name: "where",
                         value: "within_distance(\(geoField), geom'POINT(\(c.longitude) \(c.latitude))', \(radius)m)"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        return comps?.url
    }

    private func parseV1(_ json: [String: Any]) -> ([Row], Int)? {
        guard let records = json["records"] as? [[String: Any]] else { return nil }
        let rows = records.compactMap { rec -> Row? in
            guard let g = rec["geometry"] as? [String: Any],
                  let xy = g["coordinates"] as? [Double], xy.count >= 2 else { return nil }
            return Row(fields: rec["fields"] as? [String: Any] ?? [:], lat: xy[1], lon: xy[0])
        }
        return (rows, records.count)
    }

    private func parseV2(_ json: [String: Any]) -> ([Row], Int)? {
        guard let results = json["results"] as? [[String: Any]] else { return nil }
        let rows = results.compactMap { r -> Row? in
            guard let g = r[geoField] as? [String: Any],
                  let lat = g["lat"] as? Double, let lon = g["lon"] as? Double else { return nil }
            return Row(fields: r, lat: lat, lon: lon)
        }
        return (rows, results.count)
    }
}
