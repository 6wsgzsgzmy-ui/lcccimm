import CoreLocation

/// Agrège trois niveaux de sources, du plus fiable au plus général :
/// 1. données officielles des villes (Paris) ; 2. OpenStreetMap (live, national) ; 3. jeu consolidé de la Région IDF (comble les trous).
/// Un point d'un niveau inférieur situé à moins de 25 m d'un point déjà retenu est écarté.
enum ToiletService {
    static func fetch(around c: CLLocationCoordinate2D, radius: Int) async throws -> [Toilet] {
        async let osmResult = OverpassSource.fetch(around: c, radius: radius)
        async let cityData = OpenDataSource.fetchAll(consolidated: false, around: c, radius: radius)
        async let regional = OpenDataSource.fetchAll(consolidated: true, around: c, radius: radius)
        let (osm, city, consolidated) = await (osmResult, cityData, regional)

        let osmToilets: [Toilet]
        switch osm {
        case .success(let toilets):
            osmToilets = toilets
        case .failure(let error):
            if city.isEmpty && consolidated.isEmpty { throw error }   // on n'échoue que si aucune source n'a répondu
            osmToilets = []
        }

        var result = city
        result += osmToilets.filter { !isNear($0, city) }
        let base = result
        result += consolidated.filter { !isNear($0, base) }
        return result
    }

    private static func isNear(_ t: Toilet, _ list: [Toilet]) -> Bool {
        list.contains { $0.location.distance(from: t.location) < 25 }
    }
}
