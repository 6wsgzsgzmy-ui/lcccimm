import CoreLocation

struct Toilet: Identifiable, Hashable {
    let id: String
    let latitude: Double
    let longitude: Double
    let tags: [String: String]
    var source: String = "OpenStreetMap"

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation { .init(latitude: latitude, longitude: longitude) }
    var name: String { tags["name"] ?? "Toilettes publiques" }
    var openingHours: String? { tags["opening_hours"] }
    var address: String? { tags["address"] }

    var details: [String] {
        var d: [String] = []
        switch tags["fee"] {
        case "yes": d.append("Payant")
        case "no": d.append("Gratuit")
        default: break
        }
        if tags["wheelchair"] == "yes" { d.append("Accessible PMR") }
        if tags["changing_table"] == "yes" { d.append("Table à langer") }
        if tags["access"] == "customers" { d.append("Réservé aux clients") }
        return d
    }
}
