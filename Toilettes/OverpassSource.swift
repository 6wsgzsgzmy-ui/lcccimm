import CoreLocation

/// Source n°1 : OpenStreetMap (amenity=toilets) via l'API Overpass. Couverture nationale.
enum OverpassSource {
    private static let endpoints = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter"
    ]

    static func fetch(around c: CLLocationCoordinate2D, radius: Int) async -> Result<[Toilet], Error> {
        let query = """
        [out:json][timeout:25];
        nwr["amenity"="toilets"](around:\(radius),\(c.latitude),\(c.longitude));
        out center tags;
        """
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")

        var lastError: Error = URLError(.badServerResponse)
        for endpoint in endpoints {
            do {
                var req = URLRequest(url: URL(string: endpoint)!)
                req.httpMethod = "POST"
                req.httpBody = body.data(using: .utf8)
                req.timeoutInterval = 30
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.setValue("ToilettesFrance/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return .success(try parse(data))
            } catch {
                lastError = error
            }
        }
        return .failure(lastError)
    }

    private struct Response: Decodable { let elements: [Element] }
    private struct Element: Decodable {
        struct Center: Decodable { let lat: Double; let lon: Double }
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: Center?
        let tags: [String: String]?
    }

    private static func parse(_ data: Data) throws -> [Toilet] {
        try JSONDecoder().decode(Response.self, from: data).elements.compactMap { e in
            guard let lat = e.lat ?? e.center?.lat, let lon = e.lon ?? e.center?.lon else { return nil }
            let tags = e.tags ?? [:]
            if ["private", "no"].contains(tags["access"] ?? "") { return nil }
            return Toilet(id: "\(e.type)\(e.id)", latitude: lat, longitude: lon, tags: tags)
        }
    }
}
