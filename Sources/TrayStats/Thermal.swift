import Darwin
import IOKit.hidsystem

struct TemperatureUnavailable: Error, CustomStringConvertible {
    let reason: String

    var description: String { reason }
}

/// Reads the Apple Silicon temperature sensors through the private IOHIDEventSystemClient API.
/// Setup never fails the caller: a setup failure is kept and thrown by every `read()`.
struct ThermalSensors {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
    private typealias SetMatching = @convention(c) (IOHIDEventSystemClient, CFDictionary) -> Void
    private typealias CopyEvent =
        @convention(c) (IOHIDServiceClient, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatValue = @convention(c) (CFTypeRef, UInt32) -> Double

    private struct Connection {
        let client: IOHIDEventSystemClient
        let sensors: [(name: String, service: IOHIDServiceClient)]
        let copyEvent: CopyEvent
        let getFloatValue: GetFloatValue
    }

    // kIOHIDEventTypeTemperature in IOHIDFamily IOHIDEventTypes.h.
    private static let temperatureEvent: Int64 = 15
    // IOHIDEventFieldBase(type) is type << 16; the temperature level is the first field.
    private static let temperatureLevel = UInt32(temperatureEvent) << 16
    // Swift does not import RTLD_DEFAULT; dlfcn.h defines it as (void *)-2.
    private static var defaultHandle: UnsafeMutableRawPointer? { .init(bitPattern: -2) }

    private let connection: Result<Connection, TemperatureUnavailable>

    init() {
        do {
            connection = .success(try Self.connect())
        } catch {
            connection = .failure(error)
        }
    }

    /// One reading per CPU die sensor service that answers; a service with no event is left out.
    func read() throws(TemperatureUnavailable) -> [SensorReading] {
        let connection = try connection.get()

        return connection.sensors.compactMap { sensor in
            connection.copyEvent(sensor.service, Self.temperatureEvent, 0, 0).map {
                SensorReading(
                    name: sensor.name,
                    celsius: connection.getFloatValue(
                        $0.takeRetainedValue(), Self.temperatureLevel))
            }
        }
    }

    private static func connect() throws(TemperatureUnavailable) -> Connection {
        let create = try symbol("IOHIDEventSystemClientCreate", as: Create.self)
        let setMatching = try symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self)
        let copyEvent = try symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self)
        let getFloatValue = try symbol("IOHIDEventGetFloatValue", as: GetFloatValue.self)

        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            throw TemperatureUnavailable(reason: "could not create the HID event system client")
        }
        // Apple vendor usage page 0xff00, usage 5: temperature sensor services.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)

        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let sensors = services.compactMap {
            service -> (name: String, service: IOHIDServiceClient)? in
            guard
                let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)
                    as? String,
                isDieSensor(name)
            else { return nil }

            return (name, service)
        }
        guard !sensors.isEmpty else {
            throw TemperatureUnavailable(reason: "no CPU die temperature sensor")
        }

        return Connection(
            client: client, sensors: sensors, copyEvent: copyEvent, getFloatValue: getFloatValue)
    }

    private static func symbol<Function>(_ name: String, as type: Function.Type)
        throws(TemperatureUnavailable) -> Function
    {
        guard let address = dlsym(defaultHandle, name) else {
            throw TemperatureUnavailable(reason: "\(name) not found")
        }

        return unsafeBitCast(address, to: type)
    }
}
