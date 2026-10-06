import AinkradAppKit
import os

/// The module's loggers, one per area, all under the shared Ainkrad subsystem
/// (`AinkradLog`) so a single Console filter covers the host and Leyline.
///
/// Interpolated errors keep the default private privacy: a key error can name
/// the path of a plaintext private key.
enum Log {
    static let persistence = AinkradLog.logger(app: "leyline", area: "persistence")
    static let keys = AinkradLog.logger(app: "leyline", area: "keys")
}
